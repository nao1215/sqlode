import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/string
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/context.{type AnalyzerContext}
import sqlode/query_analyzer/placeholder

pub fn infer_insert_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)

  case regexp.scan(ctx.insert_re, normalized) {
    [match, ..] ->
      case match.submatches {
        [Some(table_name), Some(columns_text), Some(values_text)] -> {
          let columns =
            context.split_csv(columns_text)
            |> list.map(naming.normalize_identifier)

          let values =
            context.split_csv(values_text)
            |> list.map(string.trim)

          map_insert_columns(
            engine,
            catalog,
            table_name,
            columns,
            values,
            1,
            [],
          )
          |> list.reverse
        }
        _ -> []
      }
    [] -> []
  }
}

fn map_insert_columns(
  engine: model.Engine,
  catalog: model.Catalog,
  table_name: String,
  columns: List(String),
  values: List(String),
  occurrence: Int,
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case columns, values {
    [], _ | _, [] -> acc
    [column_name, ..rest_columns], [value, ..rest_values] -> {
      let acc = case
        placeholder.placeholder_index_for_token(engine, value, occurrence)
      {
        Some(index) ->
          case context.find_column(catalog, table_name, column_name) {
            Some(column) -> [#(index, column), ..acc]
            None -> acc
          }
        None -> acc
      }

      let next_occurrence = case placeholder.is_placeholder_token(value) {
        True -> occurrence + 1
        False -> occurrence
      }

      map_insert_columns(
        engine,
        catalog,
        table_name,
        rest_columns,
        rest_values,
        next_occurrence,
        acc,
      )
    }
  }
}

pub fn infer_equality_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)
  let table_name = context.primary_table_name(ctx, normalized)

  case table_name {
    None -> []
    Some(name) ->
      scan_equality_matches(
        engine,
        catalog,
        name,
        regexp.scan(ctx.equality_re, normalized),
        1,
        [],
      )
      |> list.reverse
  }
}

fn scan_equality_matches(
  engine: model.Engine,
  catalog: model.Catalog,
  table_name: String,
  matches: List(regexp.Match),
  occurrence: Int,
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case matches {
    [] -> acc
    [match, ..rest] ->
      case match.submatches {
        [Some(column_name), Some(token)] -> {
          let acc = case
            placeholder.placeholder_index_for_token(engine, token, occurrence)
          {
            Some(index) ->
              case
                context.find_column(
                  catalog,
                  table_name,
                  naming.normalize_identifier(column_name),
                )
              {
                Some(column) -> [#(index, column), ..acc]
                None -> acc
              }
            None -> acc
          }

          let next_occurrence = case
            placeholder.sequential_placeholder(engine)
          {
            True -> occurrence + 1
            False -> occurrence
          }

          scan_equality_matches(
            engine,
            catalog,
            table_name,
            rest,
            next_occurrence,
            acc,
          )
        }
        _ ->
          scan_equality_matches(
            engine,
            catalog,
            table_name,
            rest,
            occurrence,
            acc,
          )
      }
  }
}

pub fn infer_in_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)
  let table_name = context.primary_table_name(ctx, normalized)

  case table_name {
    None -> []
    Some(name) ->
      scan_equality_matches(
        engine,
        catalog,
        name,
        regexp.scan(ctx.in_clause_re, normalized),
        1,
        [],
      )
      |> list.reverse
  }
}

pub fn extract_type_casts(
  ctx: AnalyzerContext,
  engine: model.Engine,
  sql: String,
) -> dict.Dict(Int, model.ScalarType) {
  case engine {
    model.PostgreSQL -> {
      let normalized = context.normalize_sql(ctx, sql)
      regexp.scan(ctx.type_cast_re, normalized)
      |> list.filter_map(fn(match) {
        case match.submatches {
          [Some(ph)] -> {
            let cast_type = string.replace(match.content, ph <> "::", "")
            case
              ph
              |> string.replace("$", "")
              |> int.parse
            {
              Ok(index) -> Ok(#(index, cast_type_to_scalar(cast_type)))
              Error(_) -> Error(Nil)
            }
          }
          _ -> Error(Nil)
        }
      })
      |> list.fold(dict.new(), fn(d, entry) {
        let #(index, scalar_type) = entry
        dict.insert(d, index, scalar_type)
      })
    }
    _ -> dict.new()
  }
}

fn cast_type_to_scalar(type_name: String) -> model.ScalarType {
  let lowered = string.lowercase(string.trim(type_name))
  case lowered {
    "int" | "integer" | "bigint" | "smallint" | "serial" | "bigserial" ->
      model.IntType
    "float" | "double" | "real" | "numeric" | "decimal" -> model.FloatType
    "bool" | "boolean" -> model.BoolType
    "bytea" | "blob" | "binary" -> model.BytesType
    "uuid" -> model.UuidType
    "json" | "jsonb" -> model.JsonType
    "timestamp" | "datetime" -> model.DateTimeType
    "date" -> model.DateType
    "time" | "timetz" -> model.TimeType
    _ -> model.StringType
  }
}
