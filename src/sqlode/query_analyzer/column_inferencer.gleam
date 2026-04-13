import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, ColumnNotFound, TableNotFound,
}

pub fn infer_result_columns(
  ctx: AnalyzerContext,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> Result(List(model.ResultColumn), AnalysisError) {
  case query.command {
    model.Exec | model.ExecResult | model.ExecRows | model.ExecLastId -> Ok([])
    model.One | model.Many -> {
      let normalized = context.normalize_sql(ctx, query.sql)

      case extract_returning_columns(ctx, normalized) {
        Some(returning_cols) -> {
          let table_names = extract_table_names(ctx, normalized)
          case table_names {
            [] -> Ok([])
            [primary, ..] ->
              resolve_select_columns(
                query.name,
                returning_cols,
                catalog,
                primary,
                table_names,
              )
          }
        }
        None -> {
          let main_sql =
            strip_cte(ctx, normalized)
            |> strip_compound
          let table_names = extract_table_names(ctx, main_sql)

          case table_names {
            [] -> Ok([])
            [primary, ..] -> {
              let select_columns = extract_select_columns(ctx, main_sql)
              resolve_select_columns(
                query.name,
                select_columns,
                catalog,
                primary,
                table_names,
              )
            }
          }
        }
      }
    }
  }
}

fn strip_cte(ctx: AnalyzerContext, sql: String) -> String {
  case string.starts_with(sql, "with ") {
    False -> sql
    True -> {
      case regexp.scan(ctx.cte_re, sql) {
        [match, ..] ->
          case match.submatches {
            [Some(keyword)] -> {
              let prefix_len =
                string.length(match.content) - string.length(keyword) - 1
              string.drop_start(sql, prefix_len)
              |> string.trim
            }
            _ -> sql
          }
        [] -> sql
      }
    }
  }
}

fn strip_compound(sql: String) -> String {
  let keywords = [" union all ", " union ", " intersect ", " except "]
  strip_first_compound(sql, keywords)
}

fn strip_first_compound(sql: String, keywords: List(String)) -> String {
  case keywords {
    [] -> sql
    [keyword, ..rest] ->
      case string.split_once(sql, keyword) {
        Ok(#(before, _)) -> before |> string.trim
        Error(_) -> strip_first_compound(sql, rest)
      }
  }
}

fn extract_returning_columns(
  ctx: AnalyzerContext,
  sql: String,
) -> Option(List(String)) {
  case regexp.scan(ctx.returning_re, sql) {
    [match, ..] ->
      case match.submatches {
        [Some(columns_text)] -> {
          let cols = case string.trim(columns_text) == "*" {
            True -> ["*"]
            False -> context.split_csv(columns_text)
          }
          Some(cols)
        }
        _ -> None
      }
    [] -> None
  }
}

fn extract_table_names(ctx: AnalyzerContext, sql: String) -> List(String) {
  let primary = context.primary_table_name(ctx, sql)
  let join_tables = extract_join_tables(ctx, sql)

  case primary {
    Some(name) -> [name, ..join_tables]
    None -> join_tables
  }
}

fn extract_join_tables(ctx: AnalyzerContext, sql: String) -> List(String) {
  regexp.scan(ctx.join_re, sql)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(name)] -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

fn extract_select_columns(ctx: AnalyzerContext, sql: String) -> List(String) {
  case regexp.scan(ctx.select_columns_re, sql) {
    [match, ..] ->
      case match.submatches {
        [Some(columns_text)] -> {
          case string.trim(columns_text) == "*" {
            True -> ["*"]
            False ->
              columns_text
              |> context.split_csv
              |> list.map(fn(col) {
                let trimmed = string.trim(col)
                case string.starts_with(trimmed, "sqlc.embed(") {
                  True -> trimmed
                  False ->
                    case string.contains(trimmed, " as ") {
                      True -> {
                        let assert Ok(#(_, alias)) =
                          string.split_once(trimmed, " as ")
                        string.trim(alias)
                      }
                      False ->
                        case string.contains(trimmed, ".") {
                          True -> {
                            let parts = string.split(trimmed, ".")
                            case list.last(parts) {
                              Ok(last) -> string.trim(last)
                              Error(_) -> trimmed
                            }
                          }
                          False -> trimmed
                        }
                    }
                }
              })
          }
        }
        _ -> []
      }
    [] -> []
  }
}

fn resolve_select_columns(
  query_name: String,
  columns: List(String),
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
) -> Result(List(model.ResultColumn), AnalysisError) {
  case columns {
    ["*"] ->
      case
        catalog.tables
        |> list.find(fn(table) { table.name == primary_table })
      {
        Ok(table) ->
          Ok(
            list.map(table.columns, fn(col) {
              model.ResultColumn(
                name: col.name,
                scalar_type: col.scalar_type,
                nullable: col.nullable,
              )
            }),
          )
        Error(_) -> Error(TableNotFound(query_name:, table_name: primary_table))
      }
    _ ->
      list.try_map(columns, fn(col_name) {
        let trimmed = string.trim(col_name)
        case string.starts_with(trimmed, "sqlc.embed(") {
          True -> {
            let embed_name =
              trimmed
              |> string.replace("sqlc.embed(", "")
              |> string.replace(")", "")
              |> string.trim
              |> string.lowercase

            case
              catalog.tables
              |> list.find(fn(table) { table.name == embed_name })
            {
              Ok(table) ->
                Ok(
                  list.map(table.columns, fn(col) {
                    model.ResultColumn(
                      name: col.name,
                      scalar_type: col.scalar_type,
                      nullable: col.nullable,
                    )
                  }),
                )
              Error(_) ->
                Error(TableNotFound(query_name:, table_name: embed_name))
            }
          }
          False -> {
            let normalized_name = string.lowercase(trimmed)
            case find_column_in_tables(catalog, all_tables, normalized_name) {
              Some(column) ->
                Ok([
                  model.ResultColumn(
                    name: column.name,
                    scalar_type: column.scalar_type,
                    nullable: column.nullable,
                  ),
                ])
              None ->
                Error(ColumnNotFound(
                  query_name:,
                  table_name: primary_table,
                  column_name: normalized_name,
                ))
            }
          }
        }
      })
      |> result.map(list.flatten)
  }
}

fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(model.Column) {
  list.find_map(table_names, fn(name) {
    case context.find_column(catalog, name, column_name) {
      Some(col) -> Ok(col)
      None -> Error(Nil)
    }
  })
  |> option.from_result
}
