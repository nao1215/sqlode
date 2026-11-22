import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/internal/lexer
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer/context.{
  type AnalysisError, AmbiguousColumnName,
}
import sqlode/internal/query_analyzer/placeholder
import sqlode/internal/query_analyzer/token_utils
import sqlode/internal/query_ir

/// Structured IR variant. Consumes the pre-parsed `InsertStatement`
/// directly instead of re-scanning the token list.
pub fn infer_insert_params_from_ir(
  engine: model.Engine,
  statement: query_ir.SqlStatement,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  case statement {
    query_ir.InsertStatement(table_name:, columns:, value_groups:) ->
      map_insert_columns(
        engine,
        catalog,
        table_name,
        columns,
        value_groups,
        1,
        dict.new(),
        [],
      )
      |> list.reverse
    _ -> []
  }
}

fn map_insert_columns(
  engine: model.Engine,
  catalog: model.Catalog,
  table_name: String,
  columns: List(String),
  values: List(List(lexer.Token)),
  occurrence: Int,
  seen: dict.Dict(String, Int),
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case columns, values {
    [], _ | _, [] -> acc
    [column_name, ..rest_columns], [value_tokens, ..rest_values] -> {
      // Check if the VALUES slot is a placeholder we can hand back
      // to the column-type inferencer. We accept two shapes:
      //
      //   * a bare `?` / `:name` / `$1` token, and
      //   * `CAST(? AS <type>)` — common explicit-cast escape hatch
      //     for SQLite (`CAST(? AS BLOB)`, `CAST(? AS INTEGER)`).
      //     The placeholder still consumes a position in the SQL
      //     parameter list, so without this match the placeholder
      //     index would silently drift for every parameter that
      //     follows. (#477)
      let value_placeholder = case value_tokens {
        [lexer.Placeholder(p)] -> Some(p)
        [
          lexer.Keyword("cast"),
          lexer.LParen,
          lexer.Placeholder(p),
          lexer.Keyword("as"),
          _,
          lexer.RParen,
        ] -> Some(p)
        _ -> None
      }

      let #(maybe_index, next_occurrence, updated_seen) = case
        value_placeholder
      {
        Some(p) -> placeholder.resolve_index(engine, p, occurrence, seen)
        None -> #(None, occurrence, seen)
      }

      let acc = case maybe_index {
        Some(index) ->
          case context.find_column(catalog, table_name, column_name) {
            Some(column) -> [#(index, column), ..acc]
            None -> acc
          }
        None -> acc
      }

      map_insert_columns(
        engine,
        catalog,
        table_name,
        rest_columns,
        rest_values,
        next_occurrence,
        updated_seen,
        acc,
      )
    }
  }
}

pub fn infer_equality_params(
  engine: model.Engine,
  query_name: String,
  tokens: List(lexer.Token),
  stmt: query_ir.Stmt,
  catalog: model.Catalog,
) -> Result(List(#(Int, model.Column)), AnalysisError) {
  // Only FROM/JOIN tables of the outermost statement are in scope for
  // top-level predicates. Dropping the WITH prefix keeps CTE-internal
  // tables (which each CTE resolves against its own scope) from
  // leaking into the ambiguity check for the outer WHERE.
  let main_tokens = token_utils.strip_leading_with(tokens)
  let all_tables = token_utils.extract_table_names(main_tokens)
  case all_tables {
    [] -> Ok([])
    _ -> {
      // Prefer the IR-based walker. Token-based scanning remains the
      // fallback for:
      //
      //   * `UnstructuredStmt(..)` — the IR parser hit a construct it
      //     does not yet model; keep the existing token coverage.
      //
      //   * `InsertStmt(..)` — the IR does not carry the PostgreSQL /
      //     SQLite `ON CONFLICT … DO UPDATE SET …` tail (only MySQL's
      //     `ON DUPLICATE KEY UPDATE` is parsed, via
      //     `on_duplicate_key_update`), so falling through to the IR
      //     walker would silently drop SET-clause placeholders. Token
      //     scanning covers the whole INSERT body and keeps upsert
      //     inference working until the IR gains an `on_conflict` node.
      //     Equality predicates inside INSERT … SELECT subqueries also
      //     ride along, matching the pre-refactor behaviour.
      //
      // The IR walker itself descends into nested subqueries (EXISTS /
      // scalar / IN) and transparently unwraps `Cast(Param)`, matching
      // the source-order behaviour of
      // `token_utils.find_equality_patterns`.
      let matches = case stmt {
        query_ir.UnstructuredStmt(..) | query_ir.InsertStmt(..) ->
          token_utils.find_equality_patterns(main_tokens)
        stmt -> find_equality_matches_in_stmt(stmt)
      }
      scan_token_matches(
        engine,
        catalog,
        query_name,
        table_scope(main_tokens),
        list.map(matches, InMatch(match: _, binding: SameAsColumn)),
        1,
        dict.new(),
        [],
      )
      |> result.map(list.reverse)
    }
  }
}

// ============================================================
// IR-based equality walker (Issue #406)
// ============================================================

/// Walk a parsed `Stmt` in source order and emit an `EqualityMatch`
/// for each `col <op> placeholder` / `placeholder <op> col` /
/// `col [I]LIKE placeholder` predicate reachable from the outer
/// statement.
///
/// Scoping mirrors the token-based path: it descends through SELECT
/// items, JOIN ON clauses of the outermost FROM, outermost
/// WHERE / GROUP BY / HAVING, and (for UPDATE/DELETE) the single
/// WHERE. Nested subqueries inside `EXISTS` / scalar subqueries /
/// `IN (SELECT …)` are traversed too, because the pre-refactor
/// `token_utils.find_equality_patterns` saw every placeholder in the
/// main body regardless of paren depth. CTE bodies are excluded
/// because `infer_equality_params` already strips them via
/// `token_utils.strip_leading_with` before the ambiguity check.
fn find_equality_matches_in_stmt(
  stmt: query_ir.Stmt,
) -> List(token_utils.EqualityMatch) {
  // The legacy token-scanner treats every `col = placeholder` as a
  // potential param regardless of which clause it's in, so SET
  // assignments were caught by `find_equality_patterns` as well.
  // Mirror that by emitting matches for the assignment targets so
  // `UPDATE t SET col = $1 WHERE id = $2` still resolves $1's type.
  // The assignment values are walked too, since a value may host an
  // equality against a placeholder (`col = (SELECT x WHERE id = $1)`).
  let assignment_matches = case stmt {
    query_ir.UpdateStmt(assignments:, ..) ->
      list.filter_map(assignments, assignment_match)
    query_ir.SelectStmt(..)
    | query_ir.DeleteStmt(..)
    | query_ir.InsertStmt(..)
    | query_ir.UnstructuredStmt(..) -> []
  }
  list.append(assignment_matches, walk_stmt(stmt, equality_match))
}

/// `col <op> placeholder`, `placeholder <op> col` and
/// `col [I]LIKE placeholder`. Anything else is walked into.
fn equality_match(
  expr: query_ir.Expr,
) -> Option(List(token_utils.EqualityMatch)) {
  case expr {
    query_ir.Binary(op:, left:, right:) ->
      case token_utils.is_comparison_operator(op) {
        True -> comparison_match(left, right) |> option.map(list.wrap)
        False -> None
      }
    query_ir.LikeExpr(expr: subject, pattern:, ..) ->
      like_match(subject, pattern) |> option.map(list.wrap)
    _ -> None
  }
}

fn assignment_match(
  assignment: query_ir.Assignment,
) -> Result(token_utils.EqualityMatch, Nil) {
  case param_of(assignment.value) {
    Some(raw) ->
      Ok(token_utils.EqualityMatch(
        column_name: naming.normalize_identifier(assignment.column),
        table_qualifier: None,
        placeholder: raw,
      ))
    None -> Error(Nil)
  }
}

// ============================================================
// Walking a statement in source order
// ============================================================

/// Walk the expressions of a statement in source order. `visit` gets
/// every expression; when it returns matches the walk does not go
/// below that expression, otherwise it continues into the
/// sub-expressions and subqueries.
///
/// Scoping mirrors the token-based path: SELECT items, JOIN ON clauses
/// of the outermost FROM, WHERE / GROUP BY / HAVING / ORDER BY /
/// LIMIT / OFFSET and set operations, the SET values and WHERE of
/// UPDATE, the WHERE of DELETE, and every nested subquery. The legacy
/// `token_utils` scanners saw every placeholder in the main body
/// regardless of paren depth. CTE bodies are excluded because the
/// callers already strip them via `token_utils.strip_leading_with`.
/// INSERT and unparsed statements fall back to token scanning at the
/// call site, so they are not walked.
fn walk_stmt(
  stmt: query_ir.Stmt,
  visit: fn(query_ir.Expr) -> Option(List(a)),
) -> List(a) {
  case stmt {
    query_ir.SelectStmt(core:, ..) -> walk_core(core, visit)
    query_ir.UpdateStmt(assignments:, where_:, ..) ->
      list.flatten([
        list.flat_map(assignments, fn(a) { walk_expr(a.value, visit) }),
        walk_optional(where_, visit),
      ])
    query_ir.DeleteStmt(where_:, ..) -> walk_optional(where_, visit)
    query_ir.InsertStmt(..) | query_ir.UnstructuredStmt(..) -> []
  }
}

fn walk_core(
  core: query_ir.SelectCore,
  visit: fn(query_ir.Expr) -> Option(List(a)),
) -> List(a) {
  let walk = walk_expr(_, visit)
  list.flatten([
    list.flat_map(core.select_items, fn(item) {
      case item {
        query_ir.ExprItem(expr:, ..) -> walk(expr)
        query_ir.StarEx(..) -> []
      }
    }),
    list.flat_map(core.from, walk_join_conditions(_, visit)),
    walk_optional(core.where_, visit),
    list.flat_map(core.group_by, walk),
    walk_optional(core.having, visit),
    list.flat_map(core.order_by, fn(key) { walk(key.expr) }),
    walk_optional(core.limit, visit),
    walk_optional(core.offset, visit),
    case core.set_op {
      Some(query_ir.SetOp(right:, ..)) -> walk_core(right, visit)
      None -> []
    },
  ])
}

/// Only the ON conditions of the outermost FROM are walked. Subqueries
/// and VALUES in FROM resolve against their own scope, and the legacy
/// token-based pass skipped them via `strip_leading_with` and the
/// outermost-FROM extraction.
fn walk_join_conditions(
  from: query_ir.FromItemEx,
  visit: fn(query_ir.Expr) -> Option(List(a)),
) -> List(a) {
  case from {
    query_ir.FromJoin(left:, right:, on:, ..) ->
      list.flatten([
        walk_join_conditions(left, visit),
        walk_join_conditions(right, visit),
        case on {
          query_ir.JoinOnExpr(expr:) -> walk_expr(expr, visit)
          query_ir.JoinUsing(..) | query_ir.JoinNoCondition -> []
        },
      ])
    query_ir.FromTable(..)
    | query_ir.FromSubquery(..)
    | query_ir.FromValues(..) -> []
  }
}

fn walk_optional(
  expr: Option(query_ir.Expr),
  visit: fn(query_ir.Expr) -> Option(List(a)),
) -> List(a) {
  case expr {
    Some(e) -> walk_expr(e, visit)
    None -> []
  }
}

fn walk_expr(
  expr: query_ir.Expr,
  visit: fn(query_ir.Expr) -> Option(List(a)),
) -> List(a) {
  case visit(expr) {
    Some(matches) -> matches
    None ->
      list.flat_map(children(expr), fn(child) {
        case child {
          ChildExpr(e) -> walk_expr(e, visit)
          ChildQuery(core) -> walk_core(core, visit)
        }
      })
  }
}

/// A part of an expression the walk continues into.
type Child {
  ChildExpr(query_ir.Expr)
  ChildQuery(query_ir.SelectCore)
}

/// The sub-expressions and subqueries of `expr`, in source order.
fn children(expr: query_ir.Expr) -> List(Child) {
  let exprs = list.map(_, ChildExpr)
  let optional = fn(expr) {
    case expr {
      Some(e) -> [ChildExpr(e)]
      None -> []
    }
  }
  case expr {
    query_ir.NullLit
    | query_ir.BoolLit(..)
    | query_ir.StringLit(..)
    | query_ir.NumberLit(..)
    | query_ir.Param(..)
    | query_ir.ColumnRef(..)
    | query_ir.StarRef(..)
    | query_ir.Macro(..)
    | query_ir.RawExpr(..) -> []
    query_ir.Unary(arg:, ..) -> [ChildExpr(arg)]
    query_ir.Binary(left:, right:, ..) -> exprs([left, right])
    query_ir.Func(args:, filter:, over:, ..) ->
      list.flatten([
        exprs(list.map(args, fn(a) { a.expr })),
        optional(filter),
        case over {
          Some(spec) ->
            exprs(list.append(
              spec.partition_by,
              list.map(spec.order_by, fn(key) { key.expr }),
            ))
          None -> []
        },
      ])
    query_ir.Cast(expr: subject, ..) -> [ChildExpr(subject)]
    query_ir.Case(scrutinee:, branches:, else_:) ->
      list.flatten([
        optional(scrutinee),
        list.flat_map(branches, fn(b) { exprs([b.when_, b.then]) }),
        optional(else_),
      ])
    query_ir.InExpr(expr: subject, source:, ..) -> [
      ChildExpr(subject),
      ..case source {
        query_ir.InList(values:) -> exprs(values)
        query_ir.InSubquery(core:) -> [ChildQuery(core)]
        // Slice macros are handled by a separate inference pass.
        query_ir.InSliceMacro(..) -> []
      }
    ]
    query_ir.Exists(core:, ..) | query_ir.ScalarSubquery(core:) -> [
      ChildQuery(core),
    ]
    query_ir.Quantified(left:, right:, ..) -> exprs([left, right])
    query_ir.Between(expr: subject, low:, high:, ..) ->
      exprs([subject, low, high])
    query_ir.IsCheck(expr: subject, predicate:, ..) -> [
      ChildExpr(subject),
      ..case predicate {
        query_ir.IsDistinctFrom(target:) -> [ChildExpr(target)]
        query_ir.IsNull
        | query_ir.IsTrue
        | query_ir.IsFalse
        | query_ir.IsUnknown -> []
      }
    ]
    query_ir.LikeExpr(expr: subject, pattern:, escape:, ..) ->
      list.append(exprs([subject, pattern]), optional(escape))
    query_ir.ArrayLit(elements:) | query_ir.Tuple(elements:) -> exprs(elements)
  }
}

fn is_arithmetic_op(op: String) -> Bool {
  op == "+" || op == "-" || op == "*" || op == "/" || op == "%"
}

/// Emit a match for `ColumnRef <op> Param` or the reversed operand
/// form `Param <op> ColumnRef`. The column operand is what we infer
/// against either way — `col = ?` and `? = col` both constrain `col`.
/// A PostgreSQL-style `$1::type` cast on the placeholder side is
/// unwrapped so e.g. `score > $3::int` still binds $3 to `score`'s
/// type (the cast is separately consumed by `extract_type_casts`).
fn comparison_match(
  left: query_ir.Expr,
  right: query_ir.Expr,
) -> Option(token_utils.EqualityMatch) {
  case column_of(left), param_of(right) {
    Some(#(table, name)), Some(raw) -> Some(build_match(table, name, raw))
    _, _ ->
      case column_of(right), param_of(left) {
        Some(#(table, name)), Some(raw) -> Some(build_match(table, name, raw))
        _, _ -> None
      }
  }
}

fn like_match(
  subject: query_ir.Expr,
  pattern: query_ir.Expr,
) -> Option(token_utils.EqualityMatch) {
  case column_of(subject), param_of(pattern) {
    Some(#(table, name)), Some(raw) -> Some(build_match(table, name, raw))
    _, _ -> None
  }
}

fn column_of(expr: query_ir.Expr) -> Option(#(Option(String), String)) {
  case expr {
    query_ir.ColumnRef(table:, name:) -> Some(#(table, name))
    _ -> None
  }
}

fn param_of(expr: query_ir.Expr) -> Option(String) {
  case expr {
    query_ir.Param(raw:, ..) -> Some(raw)
    query_ir.Cast(expr: inner, ..) -> param_of(inner)
    _ -> None
  }
}

fn build_match(
  table: Option(String),
  name: String,
  placeholder: String,
) -> token_utils.EqualityMatch {
  token_utils.EqualityMatch(
    column_name: naming.normalize_identifier(name),
    table_qualifier: normalize_table_qualifier(table),
    placeholder: placeholder,
  )
}

fn normalize_table_qualifier(table: Option(String)) -> Option(String) {
  case table {
    Some(t) -> Some(string.lowercase(t))
    None -> None
  }
}

// ============================================================
// IR-based IN / quantified walker (Issue #406)
// ============================================================

/// A placeholder bound to a column: by a comparison, by
/// `col IN (placeholder)`, by `col <op> ANY|ALL|SOME(placeholder)`, by
/// `placeholder <op> ANY|ALL|SOME(col)` or by `col + placeholder`.
type InMatch {
  InMatch(match: token_utils.EqualityMatch, binding: InBinding)
}

type InBinding {
  /// `col IN (placeholder)`: the placeholder has the column's type.
  SameAsColumn
  /// `col = ANY(placeholder)`: the placeholder is an array whose
  /// elements are compared with `col`.
  ArrayOfColumn
  /// `placeholder = ANY(col)`: `col` is an array and the placeholder
  /// is compared with its elements.
  ElementOfColumn
  /// `col + placeholder`: the database gives the placeholder the type
  /// of the other operand when that operand is numeric.
  NumericOperand
}

/// The type a placeholder takes from the column it is bound to, or
/// `None` when the binding says nothing about it.
fn bind_to_column(
  binding: InBinding,
  placeholder: String,
  column: model.Column,
) -> Option(model.Column) {
  case binding, column.scalar_type {
    SameAsColumn, _ -> Some(column)
    // `ANY(sqlode.slice(ids))` already expands to one placeholder per
    // element, so a slice stays a list of scalars.
    ArrayOfColumn, scalar_type ->
      case string.starts_with(placeholder, "__sqlode_slice_") {
        True -> Some(column)
        False ->
          Some(
            model.Column(..column, scalar_type: model.ArrayType(scalar_type)),
          )
      }
    ElementOfColumn, model.ArrayType(element) ->
      Some(model.Column(..column, scalar_type: element))
    NumericOperand, model.IntType
    | NumericOperand, model.FloatType
    | NumericOperand, model.DecimalType
    -> Some(column)
    // `$1 = ANY(col)` needs `col` to be an array, and `created_at + $1`
    // takes an interval; leave the parameter uninferred rather than guess.
    ElementOfColumn, _ | NumericOperand, _ -> None
  }
}

/// Walk a parsed `Stmt` in source order and emit an `EqualityMatch`
/// for every `col IN (placeholder)` or `col <op> ANY|ALL|SOME(placeholder)`
/// predicate reachable from the outer statement.
///
/// Matches are returned in source order (interleaved). The legacy
/// token path used `list.append(find_in_patterns, find_quantified_patterns)`
/// which concatenated all IN matches before all quantified matches;
/// for `$N` placeholders the index comes from the raw text so the
/// ordering has no observable effect, and for sequential placeholders
/// the combined walker preserves source order just like the equality
/// walker that already shipped.
///
/// Only the single-placeholder shapes the token scanners matched are
/// emitted: `col IN ($1)` (one element, no subquery) and
/// `col = ANY($1)` / `= ALL` / `= SOME` (with or without an extra
/// paren wrapping the placeholder). Multi-element `IN (a, b, c)` and
/// `IN (SELECT …)` / `ANY (SELECT …)` are intentionally skipped —
/// those aren't simple single-parameter bindings.
fn find_in_quantified_matches_in_stmt(stmt: query_ir.Stmt) -> List(InMatch) {
  walk_stmt(stmt, in_quantified_match)
}

/// `col IN (placeholder, ...)`, `col <op> ANY|ALL|SOME(placeholder)`,
/// `placeholder <op> ANY|ALL|SOME(col)` and `col + placeholder`.
/// Anything else is walked into.
fn in_quantified_match(expr: query_ir.Expr) -> Option(List(InMatch)) {
  case expr {
    // `col IN ($1, $2, 'x')` — every placeholder element takes the
    // column's type. Other elements, and lists without a placeholder,
    // are walked like any expression.
    query_ir.InExpr(expr: subject, source: query_ir.InList(values), ..) ->
      case in_list_matches(subject, values) {
        [] -> None
        matches ->
          Some(
            list.map(matches, fn(m) { InMatch(match: m, binding: SameAsColumn) }),
          )
      }
    query_ir.Quantified(left:, right:, ..) ->
      quantified_match(left, right) |> option.map(list.wrap)
    query_ir.Binary(op:, left:, right:) ->
      case is_arithmetic_op(op), comparison_match(left, right) {
        True, Some(m) -> Some([InMatch(match: m, binding: NumericOperand)])
        _, _ -> None
      }
    _ -> None
  }
}

/// `col IN (v1, v2, ...)`: one match per placeholder element, in source
/// order, when the subject is a column. A placeholder can only stand for
/// a value comparable with the column, so each one takes its type.
/// `Cast(Param, _)` on an element is transparently unwrapped. Elements
/// that are not placeholders are skipped.
fn in_list_matches(
  subject: query_ir.Expr,
  values: List(query_ir.Expr),
) -> List(token_utils.EqualityMatch) {
  case column_of(subject) {
    Some(#(table, name)) ->
      list.filter_map(values, fn(value) {
        case param_of(value) {
          Some(raw) -> Ok(build_match(table, name, raw))
          None -> Error(Nil)
        }
      })
    None -> []
  }
}

/// `col <op> ANY|ALL|SOME(<placeholder>)`. The token scanner matches
/// on the literal `ANY ( placeholder )` paren shape, which the IR
/// parses as either `Quantified(right: Param)` or — when the
/// placeholder is itself parenthesised inside the ANY expression —
/// `Quantified(right: Tuple([Param]))`. Both are accepted so the
/// walker is shape-compatible with `find_quantified_patterns`.
/// `Cast(Param)` on the placeholder side is transparently unwrapped.
/// The reversed form `<placeholder> <op> ANY|ALL|SOME(col)` binds the
/// placeholder to an element of the array column.
fn quantified_match(
  left: query_ir.Expr,
  right: query_ir.Expr,
) -> Option(InMatch) {
  let right = unwrap_single_tuple(right)
  case column_of(left), param_of(right) {
    Some(#(table, name)), Some(raw) ->
      Some(InMatch(build_match(table, name, raw), ArrayOfColumn))
    _, _ ->
      case param_of(left), column_of(right) {
        Some(raw), Some(#(table, name)) ->
          Some(InMatch(build_match(table, name, raw), ElementOfColumn))
        _, _ -> None
      }
  }
}

fn unwrap_single_tuple(expr: query_ir.Expr) -> query_ir.Expr {
  case expr {
    query_ir.Tuple(elements: [only]) -> only
    _ -> expr
  }
}

/// Walk each `column <op> placeholder` / `column IN (placeholder)` /
/// quantified pattern the token scanners found and bind a parameter
/// type when the referenced column exists. Ambiguity (the column name
/// exists in more than one in-scope table and is not qualified) is
/// surfaced as `AmbiguousColumnName` so `sqlode generate` fails before
/// emitting a wrong `Params` type — the result-column inferencer has
/// raised the same diagnostic for select-list ambiguity; parameter
/// inference now behaves symmetrically. A qualified column that can't
/// be found, and an unqualified column not present in any visible
/// table, simply skip inference for that placeholder — the outer
/// analyzer still has type-cast / macro hooks to satisfy the param.
/// The tables a placeholder's column can come from. `top` are the
/// tables of the statement itself; `all` adds the tables named inside
/// its subqueries, whose predicates are scanned with the same matches.
type TableScope {
  TableScope(top: List(String), all: List(String))
}

fn table_scope(main_tokens: List(lexer.Token)) -> TableScope {
  TableScope(
    top: token_utils.extract_top_level_table_names(main_tokens),
    all: token_utils.extract_table_names(main_tokens),
  )
}

/// Resolve an unqualified column. A column of the statement's own
/// tables wins over a subquery table with the same column, so
/// `WHERE id = ? AND EXISTS (SELECT 1 FROM posts ...)` binds `id` to the
/// outer table instead of failing as ambiguous. When a subquery table
/// has the column with a different type, the placeholder may belong to
/// either scope, so it stays ambiguous. A column only a subquery table
/// has resolves against that table.
fn lookup_unqualified(
  catalog: model.Catalog,
  scope: TableScope,
  column_name: String,
) -> Result(option.Option(#(String, model.Column)), List(String)) {
  case context.find_column_in_tables(catalog, scope.top, column_name) {
    Ok(Some(#(table, column))) -> {
      let conflicting =
        scope.all
        |> list.filter(fn(other) { !list.contains(scope.top, other) })
        |> list.filter(fn(other) {
          case context.find_column(catalog, other, column_name) {
            Some(c) -> c.scalar_type != column.scalar_type
            None -> False
          }
        })
      case conflicting {
        [] -> Ok(Some(#(table, column)))
        _ -> Error([table, ..conflicting])
      }
    }
    Ok(None) -> context.find_column_in_tables(catalog, scope.all, column_name)
    Error(matching) -> Error(matching)
  }
}

fn scan_token_matches(
  engine: model.Engine,
  catalog: model.Catalog,
  query_name: String,
  scope: TableScope,
  matches: List(InMatch),
  occurrence: Int,
  seen: dict.Dict(String, Int),
  acc: List(#(Int, model.Column)),
) -> Result(List(#(Int, model.Column)), AnalysisError) {
  case matches {
    [] -> Ok(acc)
    [InMatch(match:, binding:), ..rest] -> {
      let #(maybe_index, next_occurrence, updated_seen) =
        placeholder.resolve_index(engine, match.placeholder, occurrence, seen)

      case maybe_index {
        None ->
          scan_token_matches(
            engine,
            catalog,
            query_name,
            scope,
            rest,
            next_occurrence,
            updated_seen,
            acc,
          )
        Some(index) -> {
          let lookup = case match.table_qualifier {
            Some(table) ->
              Ok(
                context.find_column(catalog, table, match.column_name)
                |> option.map(fn(col) { #(table, col) }),
              )
            None -> lookup_unqualified(catalog, scope, match.column_name)
          }
          case lookup {
            Error(matching_tables) ->
              Error(AmbiguousColumnName(
                query_name: query_name,
                column_name: match.column_name,
                matching_tables: matching_tables,
              ))
            Ok(Some(#(_table, column))) ->
              // Issue #512: a placeholder bound by `col <op> ?`
              // (equality, comparison, LIKE/ILIKE) or by `col IN (?)`
              // can never meaningfully be `NULL` on the wire.
              //
              //   * `WHERE col = ?` against `None` would emit
              //     `WHERE col = NULL`, which never matches by SQL
              //     `=` semantics — wrapping the parameter in
              //     `Option(_)` invites callers to pass `None` and
              //     silently get an always-empty result set.
              //   * `UPDATE … SET col = ?` is the user supplying the
              //     new value; clearing to NULL is expressed in SQL
              //     as a literal `SET col = NULL`, not as a parameter.
              //
              // Force `nullable: False` regardless of the column's
              // schema-level nullability so the generated parameter
              // record drops the noisy `Some(...)` wrappers at every
              // call site for these positions. INSERT VALUES sites
              // (where `None` legitimately writes NULL) keep the
              // column's nullability because they go through
              // `infer_insert_params_from_ir`, not this scanner.
              scan_token_matches(
                engine,
                catalog,
                query_name,
                scope,
                rest,
                next_occurrence,
                updated_seen,
                case bind_to_column(binding, match.placeholder, column) {
                  Some(column) -> [
                    #(index, model.Column(..column, nullable: False)),
                    ..acc
                  ]
                  None -> acc
                },
              )
            Ok(None) ->
              scan_token_matches(
                engine,
                catalog,
                query_name,
                scope,
                rest,
                next_occurrence,
                updated_seen,
                acc,
              )
          }
        }
      }
    }
  }
}

pub fn infer_in_params(
  engine: model.Engine,
  query_name: String,
  tokens: List(lexer.Token),
  stmt: query_ir.Stmt,
  catalog: model.Catalog,
) -> Result(List(#(Int, model.Column)), AnalysisError) {
  let main_tokens = token_utils.strip_leading_with(tokens)
  let all_tables = token_utils.extract_table_names(main_tokens)
  case all_tables {
    [] -> Ok([])
    _ -> {
      // Prefer the IR-based walker, mirroring `infer_equality_params`.
      // Token-based scanning remains the fallback for:
      //
      //   * `UnstructuredStmt(..)` — the IR parser hit a construct it
      //     does not yet model; keep the existing token coverage.
      //
      //   * `InsertStmt(..)` — the IR does not carry the full upsert
      //     tail (see `infer_equality_params` for context), so we keep
      //     token scanning to cover IN / quantified predicates that
      //     live inside INSERT … SELECT subqueries or similar bodies.
      //
      // The IR walker itself descends into nested subqueries and
      // transparently unwraps `Cast(Param)` on the placeholder side so
      // `col IN ($1::int)` and `col = ANY($1::int[])` still resolve.
      let matches = case stmt {
        query_ir.UnstructuredStmt(..) | query_ir.InsertStmt(..) ->
          list.append(
            token_utils.find_in_patterns(main_tokens)
              |> list.map(InMatch(match: _, binding: SameAsColumn)),
            token_utils.find_quantified_patterns(main_tokens)
              |> list.map(InMatch(match: _, binding: ArrayOfColumn)),
          )
          |> list.append(
            token_utils.find_arithmetic_patterns(main_tokens)
            |> list.map(InMatch(match: _, binding: NumericOperand)),
          )
        stmt -> find_in_quantified_matches_in_stmt(stmt)
      }
      scan_token_matches(
        engine,
        catalog,
        query_name,
        table_scope(main_tokens),
        matches,
        1,
        dict.new(),
        [],
      )
      |> result.map(list.reverse)
    }
  }
}

pub fn extract_type_casts(
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Result(dict.Dict(Int, model.ScalarType), #(Int, String)) {
  // PostgreSQL `$N::type` casts (token_utils finds these).
  let pg_casts = token_utils.find_type_casts(tokens)
  use pg_dict <- result.try(
    list.try_fold(pg_casts, dict.new(), fn(d, cast) {
      case placeholder.explicit_index(cast.placeholder) {
        Some(index) ->
          case cast_type_to_scalar(cast.cast_type) {
            Ok(scalar_type) -> Ok(dict.insert(d, index, scalar_type))
            Error(Nil) -> Error(#(index, string.trim(cast.cast_type)))
          }
        None -> Ok(d)
      }
    }),
  )
  // SQL-standard `CAST(placeholder AS type)` — walk the token stream
  // with an occurrence counter so SQLite anonymous `?` placeholders
  // get the correct 1-based index (same logic as
  // `scan_int_context_indices`).
  let cast_hints = scan_cast_hints(tokens, engine, 1, [])
  use cast_dict <- result.try(
    list.try_fold(cast_hints, pg_dict, fn(d, pair) {
      let #(index, type_name) = pair
      case cast_type_to_scalar(type_name) {
        Ok(scalar_type) -> Ok(dict.insert(d, index, scalar_type))
        Error(Nil) -> Error(#(index, string.trim(type_name)))
      }
    }),
  )
  Ok(cast_dict)
}

/// Walk the token stream counting placeholder occurrences (1-based)
/// and collect `CAST(placeholder AS type)` patterns with the
/// resolved occurrence index.
fn scan_cast_hints(
  tokens: List(lexer.Token),
  engine: model.Engine,
  occurrence: Int,
  acc: List(#(Int, String)),
) -> List(#(Int, String)) {
  case tokens {
    [] -> list.reverse(acc)
    // CAST(placeholder AS ident)
    [
      lexer.Keyword("cast"),
      lexer.LParen,
      lexer.Placeholder(raw),
      lexer.Keyword("as"),
      lexer.Ident(t),
      lexer.RParen,
      ..rest
    ] -> {
      let index = resolve_placeholder_index(engine, raw, occurrence)
      scan_cast_hints(rest, engine, occurrence + 1, [
        #(index, string.lowercase(t)),
        ..acc
      ])
    }
    // CAST(placeholder AS keyword)
    [
      lexer.Keyword("cast"),
      lexer.LParen,
      lexer.Placeholder(raw),
      lexer.Keyword("as"),
      lexer.Keyword(t),
      lexer.RParen,
      ..rest
    ] -> {
      let index = resolve_placeholder_index(engine, raw, occurrence)
      scan_cast_hints(rest, engine, occurrence + 1, [#(index, t), ..acc])
    }
    // Any other placeholder — count the occurrence but don't record a hint.
    [lexer.Placeholder(_), ..rest] ->
      scan_cast_hints(rest, engine, occurrence + 1, acc)
    [_, ..rest] -> scan_cast_hints(rest, engine, occurrence, acc)
  }
}

fn resolve_placeholder_index(
  engine: model.Engine,
  raw: String,
  occurrence: Int,
) -> Int {
  placeholder.index_of(engine, raw, occurrence)
}

fn cast_type_to_scalar(type_name: String) -> Result(model.ScalarType, Nil) {
  model.parse_sql_type(string.trim(type_name))
}

// ============================================================
// LIMIT / OFFSET integer context (Issue #491)
// ============================================================

/// Extract placeholder type hints from SQL contexts that the spec
/// requires to be integer: the expressions following `LIMIT` and
/// `OFFSET`. Each placeholder reachable from those keywords (until a
/// terminating keyword or end of statement) is pinned to `IntType`.
/// Used as a complement to `extract_type_casts` so callers can write
/// `LIMIT sqlode.arg(lim)` / `OFFSET sqlode.arg(off)` without an
/// explicit cast on engines like SQLite that cannot infer the type
/// from a bare `?` (Issue #491).
///
/// Implementation note: this works at the token level rather than the
/// IR, because the IR's `Param.index` is `0` for SQLite anonymous `?`
/// placeholders (`expr_parser.decode_placeholder` deliberately
/// returns `0` for them). The token walker assigns each placeholder
/// an occurrence index that matches what `placeholder.build`
/// computes, so the resulting dict keys line up with
/// `PlaceholderOccurrence.index` consumed by `build_params`.
pub fn extract_int_context_params(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> dict.Dict(Int, model.ScalarType) {
  let int_indices = scan_int_context_indices(tokens, engine, 1, False, [])
  list.fold(int_indices, dict.new(), fn(d, idx) {
    dict.insert(d, idx, model.IntType)
  })
}

/// Walk the token stream once, counting placeholders to assign each a
/// 1-based occurrence index, and collect those that fall inside a
/// `LIMIT` / `OFFSET` clause. `in_int_context` flips on at `LIMIT` /
/// `OFFSET` and flips off at any keyword that ends the integer
/// expression (`union`, `except`, `intersect`, `returning`, `for`).
fn scan_int_context_indices(
  tokens: List(lexer.Token),
  engine: model.Engine,
  occurrence: Int,
  in_int_context: Bool,
  acc: List(Int),
) -> List(Int) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.Keyword(k), ..rest] -> {
      let lower = string.lowercase(k)
      let next_state = case lower {
        "limit" | "offset" -> True
        "union" | "except" | "intersect" | "returning" | "for" -> False
        _ -> in_int_context
      }
      scan_int_context_indices(rest, engine, occurrence, next_state, acc)
    }
    [lexer.Placeholder(raw), ..rest] -> {
      let assigned = placeholder.index_of(engine, raw, occurrence)
      let acc = case in_int_context {
        True -> [assigned, ..acc]
        False -> acc
      }
      scan_int_context_indices(
        rest,
        engine,
        occurrence + 1,
        in_int_context,
        acc,
      )
    }
    [_, ..rest] ->
      scan_int_context_indices(rest, engine, occurrence, in_int_context, acc)
  }
}
