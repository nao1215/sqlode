import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, ColumnNotFound, TableNotFound,
}

type ExtractedColumn {
  ExtractedColumn(
    name: String,
    source_table: Option(String),
    expression: Option(String),
  )
}

type JoinKind {
  LeftJoin
  RightJoin
  FullJoin
  OtherJoin
}

pub fn infer_result_columns(
  ctx: AnalyzerContext,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> Result(List(model.ResultColumn), AnalysisError) {
  case query.command {
    model.Exec
    | model.ExecResult
    | model.ExecRows
    | model.ExecLastId
    | model.BatchExec
    | model.CopyFrom -> Ok([])
    model.One | model.Many | model.BatchOne | model.BatchMany -> {
      let normalized = context.normalize_sql(ctx, query.sql)

      case extract_returning_columns(ctx, normalized) {
        Some(returning_cols) -> {
          let table_names = extract_table_names(ctx, normalized)
          let nullable_tables = extract_nullable_tables(ctx, normalized)
          case table_names {
            [] -> Ok([])
            [primary, ..] ->
              resolve_select_columns(
                query.name,
                returning_cols,
                catalog,
                primary,
                table_names,
                nullable_tables,
              )
          }
        }
        None -> {
          let main_sql =
            strip_cte(ctx, normalized)
            |> strip_compound
          let table_names = extract_table_names(ctx, main_sql)
          let nullable_tables = extract_nullable_tables(ctx, main_sql)

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
                nullable_tables,
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
) -> Option(List(ExtractedColumn)) {
  case regexp.scan(ctx.returning_re, sql) {
    [match, ..] ->
      case match.submatches {
        [Some(columns_text)] -> {
          let cols = case string.trim(columns_text) == "*" {
            True -> [
              ExtractedColumn(name: "*", source_table: None, expression: None),
            ]
            False ->
              context.split_csv(columns_text)
              |> list.map(fn(c) {
                ExtractedColumn(
                  name: string.trim(c),
                  source_table: None,
                  expression: None,
                )
              })
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
  extract_join_info(ctx, sql)
  |> list.map(fn(info) { info.0 })
}

fn extract_join_info(
  ctx: AnalyzerContext,
  sql: String,
) -> List(#(String, JoinKind)) {
  regexp.scan(ctx.join_re, sql)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(join_type), Some(name)] -> {
        let kind = case string.lowercase(join_type) {
          "left" -> LeftJoin
          "right" -> RightJoin
          "full" -> FullJoin
          _ -> OtherJoin
        }
        Ok(#(name, kind))
      }
      [None, Some(name)] -> Ok(#(name, OtherJoin))
      _ -> Error(Nil)
    }
  })
}

fn extract_nullable_tables(ctx: AnalyzerContext, sql: String) -> List(String) {
  let primary = context.primary_table_name(ctx, sql)
  let joins = extract_join_info(ctx, sql)

  let nullable_joined =
    list.filter_map(joins, fn(j) {
      case j.1 {
        LeftJoin | FullJoin -> Ok(j.0)
        _ -> Error(Nil)
      }
    })

  let primary_nullable =
    list.any(joins, fn(j) {
      case j.1 {
        RightJoin | FullJoin -> True
        _ -> False
      }
    })

  case primary_nullable, primary {
    True, Some(name) -> [name, ..nullable_joined]
    _, _ -> nullable_joined
  }
}

fn extract_select_columns(
  ctx: AnalyzerContext,
  sql: String,
) -> List(ExtractedColumn) {
  case regexp.scan(ctx.select_columns_re, sql) {
    [match, ..] ->
      case match.submatches {
        [Some(columns_text)] -> {
          case string.trim(columns_text) == "*" {
            True -> [
              ExtractedColumn(name: "*", source_table: None, expression: None),
            ]
            False ->
              columns_text
              |> context.split_csv
              |> list.map(fn(col) {
                let trimmed = string.trim(col)
                case string.starts_with(trimmed, "sqlc.embed(") {
                  True ->
                    ExtractedColumn(
                      name: trimmed,
                      source_table: None,
                      expression: None,
                    )
                  False ->
                    case split_last_as(trimmed) {
                      Some(#(expr_part, alias_part)) -> {
                        let expr_trimmed = string.trim(expr_part)
                        let table = extract_table_qualifier(expr_trimmed)
                        ExtractedColumn(
                          name: string.trim(alias_part),
                          source_table: table,
                          expression: Some(expr_trimmed),
                        )
                      }
                      None ->
                        case string.contains(trimmed, ".") {
                          True -> {
                            let parts = string.split(trimmed, ".")
                            let table = case parts {
                              [t, _] -> Some(string.trim(t))
                              _ -> None
                            }
                            let name = case list.last(parts) {
                              Ok(last) -> string.trim(last)
                              Error(_) -> trimmed
                            }
                            ExtractedColumn(
                              name:,
                              source_table: table,
                              expression: None,
                            )
                          }
                          False ->
                            ExtractedColumn(
                              name: trimmed,
                              source_table: None,
                              expression: None,
                            )
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

/// Split on the last top-level " as " (outside parentheses).
/// This avoids splitting on AS inside CAST(... AS type).
fn split_last_as(s: String) -> Option(#(String, String)) {
  let lowered = string.lowercase(s)
  split_last_as_loop(lowered, s, 0, 0, -1)
}

fn split_last_as_loop(
  lowered: String,
  original: String,
  idx: Int,
  depth: Int,
  last_pos: Int,
) -> Option(#(String, String)) {
  case string.pop_grapheme(lowered) {
    Error(_) ->
      case last_pos >= 0 {
        True ->
          Some(#(
            string.slice(original, 0, last_pos),
            string.slice(original, last_pos + 4, string.length(original)),
          ))
        False -> None
      }
    Ok(#(g, rest)) ->
      case g {
        "(" -> split_last_as_loop(rest, original, idx + 1, depth + 1, last_pos)
        ")" -> {
          let new_depth = case depth > 0 {
            True -> depth - 1
            False -> 0
          }
          split_last_as_loop(rest, original, idx + 1, new_depth, last_pos)
        }
        " " ->
          case depth == 0 && string.starts_with(rest, "as ") {
            True ->
              split_last_as_loop(
                string.drop_start(rest, 3),
                original,
                idx + 4,
                depth,
                idx,
              )
            False ->
              split_last_as_loop(rest, original, idx + 1, depth, last_pos)
          }
        _ -> split_last_as_loop(rest, original, idx + 1, depth, last_pos)
      }
  }
}

fn extract_table_qualifier(expr: String) -> Option(String) {
  case string.contains(expr, ".") {
    True -> {
      let parts = string.split(expr, ".")
      case parts {
        [table, _] -> Some(string.trim(table))
        _ -> None
      }
    }
    False -> None
  }
}

fn resolve_select_columns(
  query_name: String,
  columns: List(ExtractedColumn),
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
  nullable_tables: List(String),
) -> Result(List(model.ResultColumn), AnalysisError) {
  case columns {
    [ExtractedColumn(name: "*", ..)] ->
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
                nullable: col.nullable
                  || list.contains(nullable_tables, primary_table),
                source_table: Some(primary_table),
              )
            }),
          )
        Error(_) -> Error(TableNotFound(query_name:, table_name: primary_table))
      }
    _ ->
      list.try_map(columns, fn(extracted) {
        let trimmed = string.trim(extracted.name)
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
                Ok([
                  model.EmbeddedColumn(
                    name: embed_name,
                    table_name: embed_name,
                    columns: table.columns,
                  ),
                ])
              Error(_) ->
                Error(TableNotFound(query_name:, table_name: embed_name))
            }
          }
          False -> {
            let normalized_name = string.lowercase(trimmed)
            case extracted.source_table {
              Some(table) ->
                case context.find_column(catalog, table, normalized_name) {
                  Some(column) ->
                    Ok([
                      model.ResultColumn(
                        name: column.name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, table),
                        source_table: Some(table),
                      ),
                    ])
                  None ->
                    case extracted.expression {
                      Some(expr) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type(expr, catalog, all_tables)
                        Ok([
                          model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          ),
                        ])
                      }
                      None ->
                        Error(ColumnNotFound(
                          query_name:,
                          table_name: table,
                          column_name: normalized_name,
                        ))
                    }
                }
              None ->
                case
                  find_column_in_tables(catalog, all_tables, normalized_name)
                {
                  Some(#(found_table, column)) ->
                    Ok([
                      model.ResultColumn(
                        name: column.name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, found_table),
                        source_table: Some(found_table),
                      ),
                    ])
                  None ->
                    case extracted.expression {
                      Some(expr) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type(expr, catalog, all_tables)
                        Ok([
                          model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          ),
                        ])
                      }
                      None ->
                        Error(ColumnNotFound(
                          query_name:,
                          table_name: primary_table,
                          column_name: normalized_name,
                        ))
                    }
                }
            }
          }
        }
      })
      |> result.map(list.flatten)
  }
}

fn infer_expression_type(
  expr: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  let lowered = string.lowercase(string.trim(expr))
  infer_expression_type_dispatch(lowered, catalog, table_names)
}

fn infer_expression_type_dispatch(
  lowered: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  let prefixes = [
    #("count(", InferCount),
    #("sum(", InferSum),
    #("avg(", InferAvg),
    #("min(", InferMinMax),
    #("max(", InferMinMax),
    #("row_number(", InferRowNumber),
    #("rank(", InferRowNumber),
    #("dense_rank(", InferRowNumber),
    #("coalesce(", InferCoalesce),
    #("cast(", InferCast),
    #("case ", InferCase),
    #("'", InferStringLiteral),
  ]
  case find_matching_prefix(lowered, prefixes) {
    Some(InferCount) -> #(model.IntType, False)
    Some(InferSum) -> {
      let inner_type = infer_aggregate_inner_type(lowered, catalog, table_names)
      #(inner_type, True)
    }
    Some(InferAvg) -> #(model.FloatType, True)
    Some(InferMinMax) -> {
      let inner_type = infer_aggregate_inner_type(lowered, catalog, table_names)
      #(inner_type, True)
    }
    Some(InferRowNumber) -> #(model.IntType, False)
    Some(InferCoalesce) -> {
      let inner = extract_function_arg(lowered)
      case resolve_column_type(string.trim(inner), catalog, table_names) {
        Some(t) -> #(t, False)
        None -> #(model.StringType, False)
      }
    }
    Some(InferCast) ->
      case string.split_once(lowered, " as ") {
        Ok(#(_, type_part)) -> {
          let type_text = type_part |> string.replace(")", "") |> string.trim
          case model.parse_sql_type(type_text) {
            Ok(scalar_type) -> #(scalar_type, True)
            Error(_) -> #(model.StringType, True)
          }
        }
        Error(_) -> #(model.StringType, True)
      }
    Some(InferCase) -> #(model.StringType, True)
    Some(InferStringLiteral) -> #(model.StringType, False)
    None ->
      case is_integer_literal(lowered) {
        True -> #(model.IntType, False)
        False ->
          case lowered == "true" || lowered == "false" {
            True -> #(model.BoolType, False)
            False -> #(model.StringType, True)
          }
      }
  }
}

type ExprKind {
  InferCount
  InferSum
  InferAvg
  InferMinMax
  InferRowNumber
  InferCoalesce
  InferCast
  InferCase
  InferStringLiteral
}

fn find_matching_prefix(
  lowered: String,
  rules: List(#(String, ExprKind)),
) -> Option(ExprKind) {
  case rules {
    [] -> None
    [#(prefix, kind), ..rest] ->
      case string.starts_with(lowered, prefix) {
        True -> Some(kind)
        False -> find_matching_prefix(lowered, rest)
      }
  }
}

fn infer_aggregate_inner_type(
  func_expr: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> model.ScalarType {
  let inner = extract_function_arg(func_expr)
  case resolve_column_type(string.trim(inner), catalog, table_names) {
    Some(t) -> t
    None -> model.IntType
  }
}

fn extract_function_arg(func_expr: String) -> String {
  case string.split_once(func_expr, "(") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, ")") {
        Ok(#(arg, _)) -> {
          // For multi-arg functions, take the first arg
          case string.split_once(arg, ",") {
            Ok(#(first, _)) -> string.trim(first)
            Error(_) -> string.trim(arg)
          }
        }
        Error(_) -> rest
      }
    Error(_) -> func_expr
  }
}

fn resolve_column_type(
  name: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> Option(model.ScalarType) {
  // Try table.column format
  let col_name = case string.split_once(name, ".") {
    Ok(#(_, col)) -> string.trim(col)
    Error(_) -> name
  }
  case find_column_in_tables(catalog, table_names, col_name) {
    Some(#(_, column)) -> Some(column.scalar_type)
    None -> None
  }
}

fn is_integer_literal(s: String) -> Bool {
  !string.is_empty(s)
  && string.to_utf_codepoints(s)
  |> list.all(fn(cp) {
    let value = string.utf_codepoint_to_int(cp)
    value >= 48 && value <= 57
  })
}

fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(#(String, model.Column)) {
  list.find_map(table_names, fn(name) {
    case context.find_column(catalog, name, column_name) {
      Some(col) -> Ok(#(name, col))
      None -> Error(Nil)
    }
  })
  |> option.from_result
}
