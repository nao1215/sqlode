import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import sqlode/model
import sqlode/naming

type PlaceholderOccurrence {
  PlaceholderOccurrence(index: Int, token: String, default_name: String)
}

type AnalyzerContext {
  AnalyzerContext(
    naming: naming.NamingContext,
    insert_re: regexp.Regexp,
    equality_re: regexp.Regexp,
    postgresql_placeholder_re: regexp.Regexp,
    mysql_placeholder_re: regexp.Regexp,
    sqlite_placeholder_re: regexp.Regexp,
    whitespace_re: regexp.Regexp,
    table_from_re: regexp.Regexp,
    table_into_re: regexp.Regexp,
    table_update_re: regexp.Regexp,
    table_delete_re: regexp.Regexp,
    cte_re: regexp.Regexp,
    returning_re: regexp.Regexp,
    join_re: regexp.Regexp,
    select_columns_re: regexp.Regexp,
  )
}

fn new_analyzer_context(naming_ctx: naming.NamingContext) -> AnalyzerContext {
  let assert Ok(insert_re) =
    regexp.from_string(
      "insert\\s+into\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(([^)]*)\\)\\s*values\\s*\\(([^)]*)\\)",
    )
  let assert Ok(equality_re) =
    regexp.from_string(
      "([a-zA-Z_][a-zA-Z0-9_.]*)\\s*=\\s*(\\$[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )
  let assert Ok(postgresql_placeholder_re) = regexp.from_string("(\\$[0-9]+)")
  let assert Ok(mysql_placeholder_re) = regexp.from_string("(\\?)")
  let assert Ok(sqlite_placeholder_re) =
    regexp.from_string(
      "(\\?[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )
  let assert Ok(whitespace_re) = regexp.from_string("\\s+")
  let assert Ok(table_from_re) =
    regexp.from_string("from\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_into_re) =
    regexp.from_string("into\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_update_re) =
    regexp.from_string("update\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_delete_re) =
    regexp.from_string("delete\\s+from\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(cte_re) =
    regexp.from_string("^with\\s+.+\\)\\s+(select|insert|update|delete)\\s")
  let assert Ok(returning_re) =
    regexp.from_string("returning\\s+(.+?)\\s*;?\\s*$")
  let assert Ok(join_re) =
    regexp.from_string("join\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s")
  let assert Ok(select_columns_re) =
    regexp.from_string("select\\s+(.+?)\\s+from\\s")

  AnalyzerContext(
    naming: naming_ctx,
    insert_re:,
    equality_re:,
    postgresql_placeholder_re:,
    mysql_placeholder_re:,
    sqlite_placeholder_re:,
    whitespace_re:,
    table_from_re:,
    table_into_re:,
    table_update_re:,
    table_delete_re:,
    cte_re:,
    returning_re:,
    join_re:,
    select_columns_re:,
  )
}

pub fn analyze_queries(
  engine: model.Engine,
  catalog: model.Catalog,
  naming_ctx: naming.NamingContext,
  queries: List(model.ParsedQuery),
) -> List(model.AnalyzedQuery) {
  let ctx = new_analyzer_context(naming_ctx)
  list.map(queries, analyze_query(ctx, engine, catalog, _))
}

fn analyze_query(
  ctx: AnalyzerContext,
  engine: model.Engine,
  catalog: model.Catalog,
  query: model.ParsedQuery,
) -> model.AnalyzedQuery {
  let occurrences = extract_placeholder_occurrences(ctx, engine, query.sql)
  let params = build_params(ctx, engine, query, catalog, occurrences)
  let result_columns = infer_result_columns(ctx, query, catalog)

  model.AnalyzedQuery(base: query, params:, result_columns:)
}

fn build_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
  occurrences: List(PlaceholderOccurrence),
) -> List(model.QueryParam) {
  let inferences =
    list.append(
      infer_insert_params(ctx, engine, query, catalog),
      infer_equality_params(ctx, engine, query, catalog),
    )

  let macro_dict = build_macro_dict(query.macros)
  let inference_dict = build_inference_dict(inferences)

  unique_occurrences(occurrences)
  |> list.map(fn(occurrence) {
    let macro_info =
      dict.get(macro_dict, occurrence.index) |> option.from_result
    let inferred =
      dict.get(inference_dict, occurrence.index) |> option.from_result

    let #(field_name, scalar_type, nullable, is_list) = case macro_info {
      Some(model.SqlcArg(name:, ..)) -> {
        let st = case inferred {
          Some(column) -> column.scalar_type
          None -> model.StringType
        }
        let n = case inferred {
          Some(column) -> column.nullable
          None -> False
        }
        #(naming.to_snake_case(ctx.naming, name), st, n, False)
      }
      Some(model.SqlcNarg(name:, ..)) -> {
        let st = case inferred {
          Some(column) -> column.scalar_type
          None -> model.StringType
        }
        #(naming.to_snake_case(ctx.naming, name), st, True, False)
      }
      Some(model.SqlcSlice(name:, ..)) -> {
        let st = case inferred {
          Some(column) -> column.scalar_type
          None -> model.StringType
        }
        #(naming.to_snake_case(ctx.naming, name), st, False, True)
      }
      None ->
        case inferred {
          Some(column) -> #(
            naming.to_snake_case(ctx.naming, column.name),
            column.scalar_type,
            column.nullable,
            False,
          )
          None -> #(occurrence.default_name, model.StringType, False, False)
        }
    }

    model.QueryParam(
      index: occurrence.index,
      field_name:,
      scalar_type:,
      nullable:,
      is_list:,
    )
  })
}

fn unique_occurrences(
  occurrences: List(PlaceholderOccurrence),
) -> List(PlaceholderOccurrence) {
  let #(_, result) =
    list.fold(occurrences, #(dict.new(), []), fn(acc, occurrence) {
      let #(seen, items) = acc
      case dict.has_key(seen, occurrence.index) {
        True -> acc
        False -> #(dict.insert(seen, occurrence.index, Nil), [
          occurrence,
          ..items
        ])
      }
    })
  list.reverse(result)
}

fn macro_index(m: model.SqlcMacro) -> Int {
  case m {
    model.SqlcArg(index: i, ..) -> i
    model.SqlcNarg(index: i, ..) -> i
    model.SqlcSlice(index: i, ..) -> i
  }
}

fn build_macro_dict(
  macros: List(model.SqlcMacro),
) -> dict.Dict(Int, model.SqlcMacro) {
  list.fold(macros, dict.new(), fn(d, m) { dict.insert(d, macro_index(m), m) })
}

fn build_inference_dict(
  inferences: List(#(Int, model.Column)),
) -> dict.Dict(Int, model.Column) {
  list.fold(inferences, dict.new(), fn(d, entry) {
    let #(index, column) = entry
    dict.insert(d, index, column)
  })
}

fn infer_insert_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = normalize_sql(ctx, query.sql)

  case regexp.scan(ctx.insert_re, normalized) {
    [match, ..] ->
      case match.submatches {
        [Some(table_name), Some(columns_text), Some(values_text)] -> {
          let columns =
            split_csv(columns_text)
            |> list.map(naming.normalize_identifier)

          let values =
            split_csv(values_text)
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
      let acc = case placeholder_index_for_token(engine, value, occurrence) {
        Some(index) ->
          case find_column(catalog, table_name, column_name) {
            Some(column) -> [#(index, column), ..acc]
            None -> acc
          }
        None -> acc
      }

      let next_occurrence = case is_placeholder_token(value) {
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

fn infer_equality_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = normalize_sql(ctx, query.sql)
  let table_name = primary_table_name(ctx, normalized)

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
            placeholder_index_for_token(engine, token, occurrence)
          {
            Some(index) ->
              case
                find_column(
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

          let next_occurrence = case sequential_placeholder(engine) {
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

fn extract_placeholder_occurrences(
  ctx: AnalyzerContext,
  engine: model.Engine,
  sql: String,
) -> List(PlaceholderOccurrence) {
  let tokens = placeholder_tokens(ctx, engine, sql)
  build_occurrences(ctx, engine, tokens, 1, [])
}

fn build_occurrences(
  ctx: AnalyzerContext,
  engine: model.Engine,
  tokens: List(String),
  occurrence: Int,
  acc: List(PlaceholderOccurrence),
) -> List(PlaceholderOccurrence) {
  case tokens {
    [] -> list.reverse(acc)
    [token, ..rest] -> {
      let index = case placeholder_index_for_token(engine, token, occurrence) {
        Some(value) -> value
        None -> occurrence
      }

      let default_name = default_param_name(ctx, token, index)

      build_occurrences(ctx, engine, rest, occurrence + 1, [
        PlaceholderOccurrence(index:, token:, default_name:),
        ..acc
      ])
    }
  }
}

fn placeholder_tokens(
  ctx: AnalyzerContext,
  engine: model.Engine,
  sql: String,
) -> List(String) {
  let re = case engine {
    model.PostgreSQL -> ctx.postgresql_placeholder_re
    model.MySQL -> ctx.mysql_placeholder_re
    model.SQLite -> ctx.sqlite_placeholder_re
  }

  regexp.scan(re, sql)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(token)] -> Ok(token)
      _ -> Error(Nil)
    }
  })
}

fn placeholder_index_for_token(
  engine: model.Engine,
  token: String,
  occurrence: Int,
) -> Option(Int) {
  case engine {
    model.PostgreSQL ->
      token
      |> string.replace("$", "")
      |> int.parse
      |> int_result_to_option
    model.MySQL -> Some(occurrence)
    model.SQLite ->
      case string.starts_with(token, "?") && token != "?" {
        True ->
          token
          |> string.replace("?", "")
          |> int.parse
          |> int_result_to_option
        False -> Some(occurrence)
      }
  }
}

fn default_param_name(ctx: AnalyzerContext, token: String, index: Int) -> String {
  case named_placeholder_name(token) {
    Some(name) -> naming.to_snake_case(ctx.naming, name)
    None -> "param" <> int.to_string(index)
  }
}

fn named_placeholder_name(token: String) -> Option(String) {
  case token {
    "?" -> None
    _ ->
      case
        string.starts_with(token, "$")
        || string.starts_with(token, ":")
        || string.starts_with(token, "@")
        || string.starts_with(token, "?")
      {
        True -> {
          let raw_name = string.slice(token, 1, string.length(token) - 1)
          case is_digits(raw_name) {
            True -> None
            False -> Some(raw_name)
          }
        }
        False -> None
      }
  }
}

fn normalize_sql(ctx: AnalyzerContext, sql: String) -> String {
  let lowered = string.lowercase(sql)

  regexp.replace(ctx.whitespace_re, lowered, " ")
  |> string.trim
}

fn primary_table_name(ctx: AnalyzerContext, sql: String) -> Option(String) {
  let regexes = [
    ctx.table_from_re,
    ctx.table_into_re,
    ctx.table_update_re,
    ctx.table_delete_re,
  ]

  find_first_match(regexes, sql)
}

fn find_first_match(regexes: List(regexp.Regexp), sql: String) -> Option(String) {
  list.find_map(regexes, fn(re) {
    case regexp.scan(re, sql) {
      [match, ..] ->
        case match.submatches {
          [Some(name)] -> Ok(name)
          _ -> Error(Nil)
        }
      [] -> Error(Nil)
    }
  })
  |> option.from_result
}

fn find_column(
  catalog: model.Catalog,
  table_name: String,
  column_name: String,
) -> Option(model.Column) {
  case
    catalog.tables
    |> list.find(fn(table) {
      table.name == naming.normalize_identifier(table_name)
    })
  {
    Ok(table) ->
      table.columns
      |> list.find(fn(column) {
        column.name == naming.normalize_identifier(column_name)
      })
      |> column_result_to_option
    Error(_) -> None
  }
}

fn split_csv(text: String) -> List(String) {
  text
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}

fn sequential_placeholder(engine: model.Engine) -> Bool {
  case engine {
    model.PostgreSQL -> False
    model.MySQL | model.SQLite -> True
  }
}

fn is_placeholder_token(value: String) -> Bool {
  string.starts_with(value, "$")
  || string.starts_with(value, ":")
  || string.starts_with(value, "@")
  || string.starts_with(value, "?")
}

fn is_digits(value: String) -> Bool {
  case value == "" {
    True -> False
    False -> all_digits(value)
  }
}

fn all_digits(value: String) -> Bool {
  case string.pop_grapheme(value) {
    Error(_) -> True
    Ok(#(char, rest)) ->
      case char {
        "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ->
          all_digits(rest)
        _ -> False
      }
  }
}

fn int_result_to_option(result: Result(Int, a)) -> Option(Int) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn column_result_to_option(
  result: Result(model.Column, a),
) -> Option(model.Column) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn infer_result_columns(
  ctx: AnalyzerContext,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(model.ResultColumn) {
  case query.command {
    model.Exec | model.ExecResult | model.ExecRows | model.ExecLastId -> []
    model.One | model.Many -> {
      let normalized = normalize_sql(ctx, query.sql)

      case extract_returning_columns(ctx, normalized) {
        Some(returning_cols) -> {
          let table_names = extract_table_names(ctx, normalized)
          case table_names {
            [] -> []
            _ ->
              resolve_select_columns(
                returning_cols,
                catalog,
                case table_names {
                  [first, ..] -> first
                  [] -> ""
                },
                table_names,
              )
          }
        }
        None -> {
          let main_sql = strip_cte(ctx, normalized)
          let table_names = extract_table_names(ctx, main_sql)

          case table_names {
            [] -> []
            [primary, ..] -> {
              let select_columns = extract_select_columns(ctx, main_sql)
              resolve_select_columns(
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
            False -> split_csv(columns_text)
          }
          Some(cols)
        }
        _ -> None
      }
    [] -> None
  }
}

fn extract_table_names(ctx: AnalyzerContext, sql: String) -> List(String) {
  let primary = primary_table_name(ctx, sql)
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
              |> split_csv
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
  columns: List(String),
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
) -> List(model.ResultColumn) {
  case columns {
    ["*"] ->
      case
        catalog.tables
        |> list.find(fn(table) { table.name == primary_table })
      {
        Ok(table) ->
          list.map(table.columns, fn(col) {
            model.ResultColumn(
              name: col.name,
              scalar_type: col.scalar_type,
              nullable: col.nullable,
            )
          })
        Error(_) -> []
      }
    _ ->
      columns
      |> list.flat_map(fn(col_name) {
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
                list.map(table.columns, fn(col) {
                  model.ResultColumn(
                    name: col.name,
                    scalar_type: col.scalar_type,
                    nullable: col.nullable,
                  )
                })
              Error(_) -> []
            }
          }
          False -> {
            let normalized_name = string.lowercase(trimmed)
            case find_column_in_tables(catalog, all_tables, normalized_name) {
              Some(column) -> [
                model.ResultColumn(
                  name: column.name,
                  scalar_type: column.scalar_type,
                  nullable: column.nullable,
                ),
              ]
              None -> [
                model.ResultColumn(
                  name: normalized_name,
                  scalar_type: model.StringType,
                  nullable: False,
                ),
              ]
            }
          }
        }
      })
  }
}

fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(model.Column) {
  list.find_map(table_names, fn(name) {
    case find_column(catalog, name, column_name) {
      Some(col) -> Ok(col)
      None -> Error(Nil)
    }
  })
  |> option.from_result
}
