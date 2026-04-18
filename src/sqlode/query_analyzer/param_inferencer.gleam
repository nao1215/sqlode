import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, AmbiguousColumnName,
}
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
      let matches = token_utils.find_equality_patterns(main_tokens)
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
