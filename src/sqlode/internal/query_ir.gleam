//// Intermediate representation shared between the query parser and the
//// query analyzer.
////
//// This module defines two layers:
////
//// - The legacy **structured IR** (`SqlStatement`, `SelectItem`,
////   `FromItem`, `JoinClause`) that identifies top-level clauses but
////   stores complex sub-expressions as raw `List(lexer.Token)`.
//// - The **expression-aware IR** (`Stmt`, `Expr`, `CteDef`, …) that
////   explicitly models the SQL subset sqlode actually needs: CTEs
////   (including nested references), select items, table refs / aliases
////   / derived tables / lateral subqueries, predicate expressions,
////   arithmetic and `CASE`, function calls and casts, `IN`, `EXISTS`,
////   `ANY`, `ALL`, `GROUP BY`, `HAVING`, window expressions, and
////   `RETURNING`.
////
//// The expression-aware IR is intended to become the single semantic
//// input for type inference; `RawExpr` / `UnstructuredStmt` remain only
//// as explicit diagnostic hooks for concrete IR gaps.

import gleam/option.{type Option}
import sqlode/internal/lexer
import sqlode/internal/model

pub type TokenizedQuery {
  TokenizedQuery(base: model.ParsedQuery, tokens: List(lexer.Token))
}

// ============================================================
// Legacy structured IR — statement-level decomposition
// ============================================================

/// Top-level statement structure extracted from the token list.
pub type SqlStatement {
  SelectStatement(
    select_items: List(SelectItem),
    from: List(FromItem),
    joins: List(JoinClause),
    where_tokens: Option(List(lexer.Token)),
    group_by_tokens: Option(List(lexer.Token)),
    having_tokens: Option(List(lexer.Token)),
    order_by_tokens: Option(List(lexer.Token)),
    limit_tokens: Option(List(lexer.Token)),
  )
  InsertStatement(
    table_name: String,
    columns: List(String),
    value_groups: List(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  UpdateStatement(
    table_name: String,
    set_tokens: List(lexer.Token),
    where_tokens: Option(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  DeleteStatement(
    table_name: String,
    where_tokens: Option(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  /// Fallback for statements that don't match the above patterns.
  UnstructuredStatement(tokens: List(lexer.Token))
}

/// A single item in a SELECT list.
pub type SelectItem {
  /// `*` or `table.*`
  StarItem(table_prefix: Option(String))
  /// An expression, possibly aliased
  ExpressionItem(tokens: List(lexer.Token), alias: Option(String))
}

/// A table or subquery in the FROM clause.
pub type FromItem {
  TableRef(name: String, alias: Option(String))
  SubqueryRef(tokens: List(lexer.Token), alias: Option(String))
}

/// A JOIN clause.
pub type JoinClause {
  JoinClause(
    table_name: String,
    alias: Option(String),
    on_tokens: Option(List(lexer.Token)),
  )
}

// ============================================================
// Expression-aware IR — the rich semantic representation
// ============================================================

/// Top-level statement shape in the expression-aware IR.
///
/// Every variant carries its own list of CTE definitions so an
/// `INSERT`/`UPDATE`/`DELETE` prefixed with `WITH` (fixture 4) is
/// modelled end-to-end instead of being stripped at a boundary.
pub type Stmt {
  SelectStmt(ctes: List(CteDef), core: SelectCore)
  InsertStmt(
    ctes: List(CteDef),
    table: String,
    columns: List(String),
    source: InsertSource,
    /// MySQL `ON DUPLICATE KEY UPDATE` assignment list. Empty when the
    /// statement has no upsert tail or the engine is not MySQL. Preserved
    /// here so downstream passes see the clause instead of the legacy
    /// "skip to RETURNING" silent drop.
    on_duplicate_key_update: List(Assignment),
    returning: List(SelectItemEx),
  )
  UpdateStmt(
    ctes: List(CteDef),
    table: String,
    alias: Option(String),
    assignments: List(Assignment),
    from: List(FromItemEx),
    where_: Option(Expr),
    returning: List(SelectItemEx),
  )
  DeleteStmt(
    ctes: List(CteDef),
    table: String,
    alias: Option(String),
    using: List(FromItemEx),
    where_: Option(Expr),
    returning: List(SelectItemEx),
  )
  /// Explicit fallback. The `reason` string is surfaced in analyzer
  /// diagnostics so the operator can see which IR gap was hit; the
  /// raw token list is preserved so legacy token-based passes can
  /// still work on it.
  UnstructuredStmt(reason: String, tokens: List(lexer.Token))
}

/// The body of a `SELECT`. Reused for subqueries (scalar, `IN`,
/// `EXISTS`) and for INSERT..SELECT.
pub type SelectCore {
  SelectCore(
    distinct: Bool,
    select_items: List(SelectItemEx),
    from: List(FromItemEx),
    where_: Option(Expr),
    group_by: List(Expr),
    having: Option(Expr),
    order_by: List(OrderKey),
    limit: Option(Expr),
    offset: Option(Expr),
    set_op: Option(SetOp),
  )
}

pub type SetOp {
  SetOp(kind: SetOpKind, all: Bool, right: SelectCore)
}

pub type SetOpKind {
  Union
  Intersect
  Except
}

pub type OrderKey {
  OrderKey(expr: Expr, descending: Bool, nulls: Option(NullsOrder))
}

pub type NullsOrder {
  NullsFirst
  NullsLast
}

/// A CTE definition. `columns` is the explicit column list when
/// present (`name(c1, c2) AS (…)`). `body` is the nested statement.
pub type CteDef {
  CteDef(name: String, columns: List(String), body: Stmt, recursive: Bool)
}

/// A select item in the expression-aware IR.
pub type SelectItemEx {
  /// `*`, `table.*`
  StarEx(table_prefix: Option(String))
  /// An expression, possibly aliased. `origin` records the source
  /// table when the expression is a simple qualified column, so
  /// result-column resolution can skip the token rescan.
  ExprItem(expr: Expr, alias: Option(String))
}

/// Items in a FROM clause.
pub type FromItemEx {
  FromTable(name: String, alias: Option(String))
  FromSubquery(core: SelectCore, alias: String, column_aliases: List(String))
  FromValues(
    rows: List(List(Expr)),
    alias: String,
    column_aliases: List(String),
  )
  FromJoin(
    left: FromItemEx,
    right: FromItemEx,
    kind: JoinKind,
    on: JoinOn,
    lateral: Bool,
  )
}

pub type JoinKind {
  InnerJoin
  LeftJoin
  RightJoin
  FullJoin
  CrossJoin
}

pub type JoinOn {
  JoinOnExpr(expr: Expr)
  JoinUsing(columns: List(String))
  JoinNoCondition
}

pub type Assignment {
  Assignment(column: String, value: Expr)
}

pub type InsertSource {
  InsertValues(rows: List(List(Expr)))
  InsertSelect(core: SelectCore)
  InsertDefaultValues
}

// ------------------------------------------------------------
// Expression AST
// ------------------------------------------------------------

/// The expression AST. Designed to cover the subset of SQL that
/// sqlode needs to infer parameter and result-column types for the
/// complex fixtures (CTE + window + CASE, LATERAL + COALESCE, EXISTS
/// + nested CASE, INSERT..SELECT..RETURNING).
pub type Expr {
  /// `NULL`
  NullLit
  /// `TRUE`, `FALSE`
  BoolLit(value: Bool)
  /// String literal
  StringLit(value: String)
  /// Numeric literal; string form preserves precision for downstream
  /// callers and lets us decide int vs float without reparsing.
  NumberLit(value: String)
  /// Parameter placeholder: `$1`, `?`, `?1`, `:name`, etc. `index`
  /// is the 1-based index sqlode assigns to the placeholder.
  Param(index: Int, raw: String)
  /// Column reference (`col` or `table.col`).
  ColumnRef(table: Option(String), name: String)
  /// `t.*` or `*` — only valid inside COUNT(*), really.
  StarRef(table: Option(String))
  /// Unary prefix operator.
  Unary(op: String, arg: Expr)
  /// Binary operator (arithmetic, comparison, logical, string, JSON).
  Binary(op: String, left: Expr, right: Expr)
  /// Function call. `distinct` covers `COUNT(DISTINCT x)`. `filter`
  /// and `over` carry the optional tail clauses.
  Func(
    name: String,
    args: List(FuncArg),
    distinct: Bool,
    filter: Option(Expr),
    over: Option(WindowSpec),
  )
  /// `CAST(expr AS type)` or the shorthand `expr::type`.
  Cast(expr: Expr, target_type: String)
  /// `CASE [scrutinee] WHEN … THEN … ELSE … END`.
  Case(scrutinee: Option(Expr), branches: List(CaseBranch), else_: Option(Expr))
  /// `expr [NOT] IN …`
  InExpr(expr: Expr, source: InSource, negated: Bool)
  /// `[NOT] EXISTS (subquery)`
  Exists(core: SelectCore, negated: Bool)
  /// Correlated scalar subquery.
  ScalarSubquery(core: SelectCore)
  /// `left op ANY|ALL (right)` — `right` may be a subquery or array.
  Quantified(op: String, left: Expr, quantifier: Quantifier, right: Expr)
  /// `expr BETWEEN low AND high`.
  Between(expr: Expr, low: Expr, high: Expr, negated: Bool)
  /// `expr IS [NOT] NULL` / `IS [NOT] TRUE|FALSE|UNKNOWN`.
  IsCheck(expr: Expr, predicate: IsPredicate, negated: Bool)
  /// `[NOT] LIKE` / `[NOT] ILIKE` / `[NOT] SIMILAR TO`.
  LikeExpr(
    expr: Expr,
    op: LikeOp,
    pattern: Expr,
    escape: Option(Expr),
    negated: Bool,
  )
  /// `ARRAY[a, b, c]`.
  ArrayLit(elements: List(Expr))
  /// Tuple / row constructor `(a, b, c)`.
  Tuple(elements: List(Expr))
  /// `sqlode.arg(name)` / `sqlode.narg(name)` / `sqlode.slice(name)` /
  /// `sqlode.embed(table)` — sqlode-specific macros.
  Macro(name: String, body: List(lexer.Token))
  /// Explicit unsupported-expression marker. Analyzer passes surface
  /// `UnsupportedExpression` when inference hits this node.
  RawExpr(reason: String, tokens: List(lexer.Token))
}

pub type FuncArg {
  FuncArg(expr: Expr)
}

pub type CaseBranch {
  CaseBranch(when_: Expr, then: Expr)
}

pub type Quantifier {
  QAny
  QAll
  QSome
}

pub type IsPredicate {
  IsNull
  IsTrue
  IsFalse
  IsUnknown
  IsDistinctFrom(target: Expr)
}

pub type LikeOp {
  Like
  Ilike
  SimilarTo
}

pub type InSource {
  InList(values: List(Expr))
  InSubquery(core: SelectCore)
  /// `IN <sqlode.slice(name)>` — a sqlode-specific variadic list.
  InSliceMacro(name: String)
}

pub type WindowSpec {
  WindowSpec(
    partition_by: List(Expr),
    order_by: List(OrderKey),
    frame: Option(List(lexer.Token)),
  )
}
