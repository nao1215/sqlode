import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{type AnalyzerContext}
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
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let all_tables = token_utils.extract_table_names(tokens)

  case all_tables {
    [] -> []
    [primary, ..] -> {
      let matches = token_utils.find_equality_patterns(tokens)
      scan_token_matches(
        engine,
        catalog,
        primary,
        all_tables,
        matches,
        1,
        dict.new(),
        [],
      )
      |> list.reverse
    }
  }
}

fn scan_token_matches(
  engine: model.Engine,
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
  matches: List(token_utils.EqualityMatch),
  occurrence: Int,
  seen: dict.Dict(String, Int),
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case matches {
    [] -> acc
    [match, ..rest] -> {
      let #(maybe_index, next_occurrence, updated_seen) =
        placeholder.resolve_index(engine, match.placeholder, occurrence, seen)

      let acc = case maybe_index {
        Some(index) -> {
          let found = case match.table_qualifier {
            Some(table) ->
              context.find_column(catalog, table, match.column_name)
            None ->
              case
                context.find_column_in_tables(
                  catalog,
                  all_tables,
                  match.column_name,
                )
              {
                Ok(Some(pair)) -> Some(pair.1)
                _ -> None
              }
          }
          case found {
            Some(column) -> [#(index, column), ..acc]
            None ->
              // Fallback: try primary table
              case
                context.find_column(catalog, primary_table, match.column_name)
              {
                Some(column) -> [#(index, column), ..acc]
                None -> acc
              }
          }
        }
        None -> acc
      }

      scan_token_matches(
        engine,
        catalog,
        primary_table,
        all_tables,
        rest,
        next_occurrence,
        updated_seen,
        acc,
      )
    }
  }
}

pub fn infer_in_params(
  _ctx: AnalyzerContext,
  engine: model.Engine,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let all_tables = token_utils.extract_table_names(tokens)

  case all_tables {
    [] -> []
    [primary, ..] -> {
      let matches = token_utils.find_in_patterns(tokens)
      scan_token_matches(
        engine,
        catalog,
        primary,
        all_tables,
        matches,
        1,
        dict.new(),
        [],
      )
      |> list.reverse
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
