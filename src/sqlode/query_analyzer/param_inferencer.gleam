import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, AmbiguousColumnName,
}
import sqlode/query_analyzer/expr_parser
import sqlode/query_analyzer/placeholder
import sqlode/query_analyzer/token_utils
import sqlode/query_ir

pub fn infer_insert_params(
  _ctx: AnalyzerContext,
  engine: model.Engine,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  case token_utils.find_insert_parts(tokens) {
    Some(parts) ->
      map_insert_columns(
        engine,
        catalog,
        parts.table_name,
        parts.columns,
        parts.values,
        1,
        dict.new(),
        [],
      )
      |> list.reverse
    None -> []
  }
}

/// Structured IR variant of `infer_insert_params`. Consumes the
/// pre-parsed `InsertStatement` directly instead of re-scanning
/// the token list.
pub fn infer_insert_params_from_ir(
  engine: model.Engine,
  statement: query_ir.SqlStatement,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  case statement {
    query_ir.InsertStatement(table_name:, columns:, value_groups:, ..) ->
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
      // Check if value is a single placeholder token
      let value_placeholder = case value_tokens {
        [lexer.Placeholder(p)] -> Some(p)
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
  _ctx: AnalyzerContext,
  engine: model.Engine,
  query_name: String,
  tokens: List(lexer.Token),
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
      let matches = case expr_parser.parse_stmt(tokens, engine) {
        query_ir.UnstructuredStmt(..) | query_ir.InsertStmt(..) ->
          token_utils.find_equality_patterns(main_tokens)
        stmt -> find_equality_matches_in_stmt(stmt)
      }
      scan_token_matches(
        engine,
        catalog,
        query_name,
        all_tables,
        matches,
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
  case stmt {
    query_ir.SelectStmt(core:, ..) -> walk_select_core(core)
    query_ir.UpdateStmt(assignments:, where_:, ..) ->
      // The legacy token-scanner treats every `col = placeholder` as a
      // potential param regardless of which clause it's in, so SET
      // assignments were caught by `find_equality_patterns` as well.
      // Mirror that by emitting matches for the assignment targets so
      // `UPDATE t SET col = $1 WHERE id = $2` still resolves $1's type.
      list.flatten([
        list.filter_map(assignments, assignment_match),
        walk_optional_expr(where_),
      ])
    query_ir.DeleteStmt(where_:, ..) -> walk_optional_expr(where_)
    // InsertStmt and UnstructuredStmt are handled at the call site by
    // falling back to token scanning; the IR walker is never invoked
    // for those branches.
    query_ir.InsertStmt(..) -> []
    query_ir.UnstructuredStmt(..) -> []
  }
}

fn assignment_match(
  assignment: query_ir.Assignment,
) -> Result(token_utils.EqualityMatch, Nil) {
  case assignment.value {
    query_ir.Param(raw:, ..) ->
      Ok(token_utils.EqualityMatch(
        column_name: naming.normalize_identifier(assignment.column),
        table_qualifier: None,
        placeholder: raw,
      ))
    _ -> Error(Nil)
  }
}

fn walk_select_core(
  core: query_ir.SelectCore,
) -> List(token_utils.EqualityMatch) {
  // Walk SELECT items as well as JOIN/WHERE/HAVING so expressions like
  // `SELECT EXISTS(SELECT 1 FROM t WHERE col = $1) …` still surface
  // the inner placeholder. The legacy token scanner saw every
  // placeholder in the main body; mirror that by descending through
  // each select-list expression.
  list.flatten([
    list.flat_map(core.select_items, walk_select_item),
    list.flat_map(core.from, walk_from_item_joins),
    walk_optional_expr(core.where_),
    list.flat_map(core.group_by, walk_expr),
    walk_optional_expr(core.having),
  ])
}

fn walk_select_item(
  item: query_ir.SelectItemEx,
) -> List(token_utils.EqualityMatch) {
  case item {
    query_ir.ExprItem(expr:, ..) -> walk_expr(expr)
    query_ir.StarEx(..) -> []
  }
}

fn walk_from_item_joins(
  from: query_ir.FromItemEx,
) -> List(token_utils.EqualityMatch) {
  case from {
    query_ir.FromJoin(left:, right:, on:, ..) ->
      list.flatten([
        walk_from_item_joins(left),
        walk_from_item_joins(right),
        walk_join_on(on),
      ])
    // Do not descend into subqueries / VALUES — those resolve against
    // their own scope and the legacy token-based pass skipped them via
    // `strip_leading_with` + the outermost-FROM extraction.
    _ -> []
  }
}

fn walk_join_on(on: query_ir.JoinOn) -> List(token_utils.EqualityMatch) {
  case on {
    query_ir.JoinOnExpr(expr:) -> walk_expr(expr)
    _ -> []
  }
}

fn walk_optional_expr(
  expr: Option(query_ir.Expr),
) -> List(token_utils.EqualityMatch) {
  case expr {
    Some(e) -> walk_expr(e)
    None -> []
  }
}

/// Walk an expression in left-to-right source order, emitting an
/// `EqualityMatch` for every comparison/LIKE that binds a column to a
/// placeholder. Nested subqueries (`EXISTS`, scalar, `IN (SELECT …)`)
/// are traversed as well so the scoping matches the token-based path
/// (which scans every token in the main body after `strip_leading_with`
/// and therefore picked up placeholders inside subqueries). `IN
/// (<list>)` and quantified forms stay the responsibility of
/// `infer_in_params`, which is out of scope for this pass.
fn walk_expr(expr: query_ir.Expr) -> List(token_utils.EqualityMatch) {
  case expr {
    // `AND` / `OR` / other boolean combinators → descend left then
    // right so source order is preserved.
    query_ir.Binary(op:, left:, right:) -> {
      case is_comparison_op(op) {
        True ->
          case comparison_match(left, right) {
            Some(m) -> [m]
            None ->
              // Not a column-vs-placeholder comparison; descend into
              // both sides so e.g. `(a = $1) AND (b = $2)` still fires.
              list.append(walk_expr(left), walk_expr(right))
          }
        False -> list.append(walk_expr(left), walk_expr(right))
      }
    }
    query_ir.LikeExpr(expr: subject, pattern:, ..) ->
      case like_match(subject, pattern) {
        Some(m) -> [m]
        None -> list.append(walk_expr(subject), walk_expr(pattern))
      }
    query_ir.Unary(arg:, ..) -> walk_expr(arg)
    query_ir.Between(expr: subject, low:, high:, ..) ->
      list.flatten([walk_expr(subject), walk_expr(low), walk_expr(high)])
    query_ir.IsCheck(expr: subject, ..) -> walk_expr(subject)
    query_ir.Case(scrutinee:, branches:, else_:) ->
      list.flatten([
        walk_optional_expr(scrutinee),
        list.flat_map(branches, fn(b) {
          list.append(walk_expr(b.when_), walk_expr(b.then))
        }),
        walk_optional_expr(else_),
      ])
    query_ir.Cast(expr: subject, ..) -> walk_expr(subject)
    query_ir.Func(args:, ..) -> list.flat_map(args, fn(a) { walk_expr(a.expr) })
    query_ir.Tuple(elements:) -> list.flat_map(elements, walk_expr)
    query_ir.ArrayLit(elements:) -> list.flat_map(elements, walk_expr)
    // Nested subqueries — descend so `SELECT EXISTS(SELECT 1 FROM t
    // WHERE col = $1)` still emits the inner match, matching the
    // token scanner's behaviour.
    query_ir.Exists(core:, ..) -> walk_select_core(core)
    query_ir.ScalarSubquery(core:) -> walk_select_core(core)
    query_ir.InExpr(expr: subject, source:, ..) ->
      list.append(walk_expr(subject), walk_in_source(source))
    query_ir.Quantified(left:, right:, ..) ->
      list.append(walk_expr(left), walk_expr(right))
    // Remaining leaf nodes (NullLit / BoolLit / StringLit / NumberLit
    // / Param / ColumnRef / StarRef / Macro / RawExpr) don't contain
    // column-vs-placeholder predicates.
    _ -> []
  }
}

fn walk_in_source(source: query_ir.InSource) -> List(token_utils.EqualityMatch) {
  case source {
    query_ir.InSubquery(core:) -> walk_select_core(core)
    query_ir.InList(values:) -> list.flat_map(values, walk_expr)
    query_ir.InSliceMacro(..) -> []
  }
}

fn is_comparison_op(op: String) -> Bool {
  op == "="
  || op == "!="
  || op == "<>"
  || op == "<"
  || op == ">"
  || op == "<="
  || op == ">="
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
fn scan_token_matches(
  engine: model.Engine,
  catalog: model.Catalog,
  query_name: String,
  all_tables: List(String),
  matches: List(token_utils.EqualityMatch),
  occurrence: Int,
  seen: dict.Dict(String, Int),
  acc: List(#(Int, model.Column)),
) -> Result(List(#(Int, model.Column)), AnalysisError) {
  case matches {
    [] -> Ok(acc)
    [match, ..rest] -> {
      let #(maybe_index, next_occurrence, updated_seen) =
        placeholder.resolve_index(engine, match.placeholder, occurrence, seen)

      case maybe_index {
        None ->
          scan_token_matches(
            engine,
            catalog,
            query_name,
            all_tables,
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
            None ->
              context.find_column_in_tables(
                catalog,
                all_tables,
                match.column_name,
              )
          }
          case lookup {
            Error(matching_tables) ->
              Error(AmbiguousColumnName(
                query_name: query_name,
                column_name: match.column_name,
                matching_tables: matching_tables,
              ))
            Ok(Some(#(_table, column))) ->
              scan_token_matches(
                engine,
                catalog,
                query_name,
                all_tables,
                rest,
                next_occurrence,
                updated_seen,
                [#(index, column), ..acc],
              )
            Ok(None) ->
              scan_token_matches(
                engine,
                catalog,
                query_name,
                all_tables,
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
  _ctx: AnalyzerContext,
  engine: model.Engine,
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> Result(List(#(Int, model.Column)), AnalysisError) {
  let main_tokens = token_utils.strip_leading_with(tokens)
  let all_tables = token_utils.extract_table_names(main_tokens)
  case all_tables {
    [] -> Ok([])
    _ -> {
      let matches =
        list.append(
          token_utils.find_in_patterns(main_tokens),
          token_utils.find_quantified_patterns(main_tokens),
        )
      scan_token_matches(
        engine,
        catalog,
        query_name,
        all_tables,
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
  _ctx: AnalyzerContext,
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Result(dict.Dict(Int, model.ScalarType), #(Int, String)) {
  case engine {
    model.PostgreSQL -> {
      let casts = token_utils.find_type_casts(tokens)
      list.try_fold(casts, dict.new(), fn(d, cast) {
        case
          cast.placeholder
          |> string.replace("$", "")
          |> int.parse
        {
          Ok(index) ->
            case cast_type_to_scalar(cast.cast_type) {
              Ok(scalar_type) -> Ok(dict.insert(d, index, scalar_type))
              Error(Nil) -> Error(#(index, string.trim(cast.cast_type)))
            }
          Error(_) -> Ok(d)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

fn cast_type_to_scalar(type_name: String) -> Result(model.ScalarType, Nil) {
  model.parse_sql_type(string.trim(type_name))
}
