import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import sqlode/model
import sqlode/naming

type PlaceholderOccurrence {
  PlaceholderOccurrence(index: Int, token: String, default_name: String)
}

pub fn analyze_queries(
  engine: model.Engine,
  catalog: model.Catalog,
  queries: List(model.ParsedQuery),
) -> List(model.AnalyzedQuery) {
  list.map(queries, analyze_query(engine, catalog, _))
}

fn analyze_query(
  engine: model.Engine,
  catalog: model.Catalog,
  query: model.ParsedQuery,
) -> model.AnalyzedQuery {
  let occurrences = extract_placeholder_occurrences(engine, query.sql)
  let params = build_params(engine, query, catalog, occurrences)
  let result_columns = infer_result_columns(query, catalog)

  model.AnalyzedQuery(base: query, params:, result_columns:)
}

fn build_params(
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
  occurrences: List(PlaceholderOccurrence),
) -> List(model.QueryParam) {
  let inferences =
    list.append(
      infer_insert_params(engine, query, catalog),
      infer_equality_params(engine, query, catalog),
    )

  unique_occurrences(occurrences, [])
  |> list.map(fn(occurrence) {
    let macro_info = find_macro(occurrence.index, query.macros)
    let inferred = find_inference(occurrence.index, inferences)

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
        #(naming.to_snake_case(name), st, n, False)
      }
      Some(model.SqlcNarg(name:, ..)) -> {
        let st = case inferred {
          Some(column) -> column.scalar_type
          None -> model.StringType
        }
        #(naming.to_snake_case(name), st, True, False)
      }
      Some(model.SqlcSlice(name:, ..)) -> {
        let st = case inferred {
          Some(column) -> column.scalar_type
          None -> model.StringType
        }
        #(naming.to_snake_case(name), st, False, True)
      }
      None ->
        case inferred {
          Some(column) -> #(
            naming.to_snake_case(column.name),
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
  acc: List(PlaceholderOccurrence),
) -> List(PlaceholderOccurrence) {
  case occurrences {
    [] -> list.reverse(acc)
    [occurrence, ..rest] ->
      case list.any(acc, fn(existing) { existing.index == occurrence.index }) {
        True -> unique_occurrences(rest, acc)
        False -> unique_occurrences(rest, [occurrence, ..acc])
      }
  }
}

fn find_macro(
  index: Int,
  macros: List(model.SqlcMacro),
) -> Option(model.SqlcMacro) {
  case macros {
    [] -> None
    [entry, ..rest] -> {
      let entry_index = case entry {
        model.SqlcArg(index: i, ..) -> i
        model.SqlcNarg(index: i, ..) -> i
        model.SqlcSlice(index: i, ..) -> i
      }
      case entry_index == index {
        True -> Some(entry)
        False -> find_macro(index, rest)
      }
    }
  }
}

fn find_inference(
  index: Int,
  inferences: List(#(Int, model.Column)),
) -> Option(model.Column) {
  case inferences {
    [] -> None
    [entry, ..rest] -> {
      let #(candidate, column) = entry
      case candidate == index {
        True -> Some(column)
        False -> find_inference(index, rest)
      }
    }
  }
}

fn infer_insert_params(
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = normalize_sql(query.sql)
  let assert Ok(re) =
    regexp.from_string(
      "insert\\s+into\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(([^)]*)\\)\\s*values\\s*\\(([^)]*)\\)",
    )

  case regexp.scan(re, normalized) {
    [match, ..] ->
      case match.submatches {
        [Some(table_name), Some(columns_text), Some(values_text)] -> {
          let columns =
            split_csv(columns_text)
            |> list.map(normalize_identifier)

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
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = normalize_sql(query.sql)
  let table_name = primary_table_name(normalized)
  let assert Ok(re) =
    regexp.from_string(
      "([a-zA-Z_][a-zA-Z0-9_.]*)\\s*=\\s*(\\$[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )

  case table_name {
    None -> []
    Some(name) ->
      scan_equality_matches(
        engine,
        catalog,
        name,
        regexp.scan(re, normalized),
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
                  normalize_identifier(column_name),
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
  engine: model.Engine,
  sql: String,
) -> List(PlaceholderOccurrence) {
  let tokens = placeholder_tokens(engine, sql)
  build_occurrences(engine, tokens, 1, [])
}

fn build_occurrences(
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

      let default_name = default_param_name(token, index)

      build_occurrences(engine, rest, occurrence + 1, [
        PlaceholderOccurrence(index:, token:, default_name:),
        ..acc
      ])
    }
  }
}

fn placeholder_tokens(engine: model.Engine, sql: String) -> List(String) {
  let pattern = case engine {
    model.PostgreSQL -> "(\\$[0-9]+)"
    model.MySQL -> "(\\?)"
    model.SQLite ->
      "(\\?[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)"
  }

  let assert Ok(re) = regexp.from_string(pattern)

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

fn default_param_name(token: String, index: Int) -> String {
  case named_placeholder_name(token) {
    Some(name) -> naming.to_snake_case(name)
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

fn normalize_sql(sql: String) -> String {
  let assert Ok(whitespace) = regexp.from_string("\\s+")
  let lowered = string.lowercase(sql)

  regexp.replace(whitespace, lowered, " ")
  |> string.trim
}

fn primary_table_name(sql: String) -> Option(String) {
  let patterns = [
    "from\\s+([a-zA-Z_][a-zA-Z0-9_]*)",
    "update\\s+([a-zA-Z_][a-zA-Z0-9_]*)",
    "delete\\s+from\\s+([a-zA-Z_][a-zA-Z0-9_]*)",
  ]

  find_first_match(patterns, sql)
}

fn find_first_match(patterns: List(String), sql: String) -> Option(String) {
  case patterns {
    [] -> None
    [pattern, ..rest] -> {
      let assert Ok(re) = regexp.from_string(pattern)

      case regexp.scan(re, sql) {
        [match, ..] ->
          case match.submatches {
            [Some(name)] -> Some(name)
            _ -> find_first_match(rest, sql)
          }
        [] -> find_first_match(rest, sql)
      }
    }
  }
}

fn find_column(
  catalog: model.Catalog,
  table_name: String,
  column_name: String,
) -> Option(model.Column) {
  case
    catalog.tables
    |> list.find(fn(table) { table.name == normalize_identifier(table_name) })
  {
    Ok(table) ->
      table.columns
      |> list.find(fn(column) {
        column.name == normalize_identifier(column_name)
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

fn normalize_identifier(identifier: String) -> String {
  identifier
  |> string.trim
  |> fn(value) {
    case string.contains(value, ".") {
      True ->
        value
        |> string.split(".")
        |> list.last
        |> result.unwrap(value)
      False -> value
    }
  }
  |> fn(value) {
    let length = string.length(value)
    case length >= 2 {
      True -> {
        let first = string.slice(value, 0, 1)
        let last = string.slice(value, length - 1, 1)
        case first == "\"" && last == "\"" {
          True -> string.slice(value, 1, length - 2)
          False ->
            case first == "`" && last == "`" {
              True -> string.slice(value, 1, length - 2)
              False -> value
            }
        }
      }
      False -> value
    }
  }
  |> string.lowercase
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
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(model.ResultColumn) {
  case query.command {
    model.Exec | model.ExecResult | model.ExecRows | model.ExecLastId -> []
    model.One | model.Many -> {
      let normalized = normalize_sql(query.sql)
      let table_name = primary_table_name(normalized)

      case table_name {
        None -> []
        Some(name) -> {
          let select_columns = extract_select_columns(normalized)
          resolve_select_columns(select_columns, catalog, name)
        }
      }
    }
  }
}

fn extract_select_columns(sql: String) -> List(String) {
  let assert Ok(re) = regexp.from_string("select\\s+(.+?)\\s+from\\s")

  case regexp.scan(re, sql) {
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
  table_name: String,
) -> List(model.ResultColumn) {
  case columns {
    ["*"] ->
      case
        catalog.tables
        |> list.find(fn(table) { table.name == table_name })
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
      list.filter_map(columns, fn(col_name) {
        let normalized_name = string.lowercase(string.trim(col_name))
        case find_column(catalog, table_name, normalized_name) {
          Some(column) ->
            Ok(model.ResultColumn(
              name: column.name,
              scalar_type: column.scalar_type,
              nullable: column.nullable,
            ))
          None ->
            Ok(model.ResultColumn(
              name: normalized_name,
              scalar_type: model.StringType,
              nullable: False,
            ))
        }
      })
  }
}
