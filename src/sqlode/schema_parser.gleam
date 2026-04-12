import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/model

pub type ParseError {
  InvalidCreateTable(detail: String)
  InvalidColumn(table: String, detail: String)
}

type ParsedSchema {
  ParsedSchema(tables: List(model.Table), enums: List(model.EnumDef))
}

pub fn parse_files(
  entries: List(#(String, String)),
) -> Result(model.Catalog, ParseError) {
  entries
  |> list.try_fold(ParsedSchema(tables: [], enums: []), fn(acc, entry) {
    let #(_path, content) = entry
    use parsed <- result.try(parse_content(content, acc.enums))
    Ok(ParsedSchema(
      tables: list.append(acc.tables, parsed.tables),
      enums: list.append(acc.enums, parsed.enums),
    ))
  })
  |> result.map(fn(schema) {
    model.Catalog(tables: schema.tables, enums: schema.enums)
  })
}

fn parse_content(
  content: String,
  known_enums: List(model.EnumDef),
) -> Result(ParsedSchema, ParseError) {
  let statements =
    content
    |> string.split(";")
    |> list.map(string.trim)
    |> list.filter(fn(statement) { statement != "" })

  let enums =
    statements
    |> list.filter_map(fn(statement) {
      let lowered = string.lowercase(statement)
      case
        string.contains(lowered, "create type")
        && string.contains(lowered, "as enum")
      {
        True -> parse_create_enum(statement)
        False -> Error(Nil)
      }
    })

  let all_enums = list.append(known_enums, enums)

  use tables <- result.try(
    statements
    |> list.try_fold([], fn(tables, statement) {
      use maybe_table <- result.try(parse_statement(statement, all_enums))
      Ok(case maybe_table {
        Some(table) -> [table, ..tables]
        None -> tables
      })
    })
    |> result.map(list.reverse),
  )

  Ok(ParsedSchema(tables:, enums:))
}

fn parse_create_enum(statement: String) -> Result(model.EnumDef, Nil) {
  case string.split_once(statement, "(") {
    Error(_) -> Error(Nil)
    Ok(#(header, body)) -> {
      let header_lower = string.lowercase(header)
      let name =
        header_lower
        |> string.replace("create type", "")
        |> string.replace("as enum", "")
        |> string.trim

      let values =
        body
        |> string.replace(")", "")
        |> string.split(",")
        |> list.map(fn(v) {
          v
          |> string.trim
          |> string.replace("'", "")
        })
        |> list.filter(fn(v) { v != "" })

      Ok(model.EnumDef(name:, values:))
    }
  }
}

fn parse_statement(
  statement: String,
  enums: List(model.EnumDef),
) -> Result(Option(model.Table), ParseError) {
  let lowered = string.lowercase(statement)

  case string.starts_with(lowered, "create table") {
    False -> Ok(None)
    True -> parse_create_table(statement, enums)
  }
}

fn parse_create_table(
  statement: String,
  enums: List(model.EnumDef),
) -> Result(Option(model.Table), ParseError) {
  use parts <- result.try(case string.split_once(statement, on: "(") {
    Ok(parts) -> Ok(parts)
    Error(_) ->
      Error(InvalidCreateTable(
        detail: "missing opening parenthesis in CREATE TABLE statement",
      ))
  })

  let #(header, raw_body) = parts
  let header_tokens =
    header
    |> string.split(" ")
    |> list.map(string.trim)
    |> list.filter(fn(token) { token != "" })

  use table_name <- result.try(
    header_tokens
    |> list.last
    |> result.map(trim_identifier)
    |> result.map_error(fn(_) {
      InvalidCreateTable(detail: "missing table name")
    }),
  )

  let body = case string.ends_with(raw_body, ")") {
    True -> string.slice(raw_body, 0, string.length(raw_body) - 1)
    False -> raw_body
  }

  use columns <- result.try(parse_columns(table_name, body, enums))

  Ok(Some(model.Table(name: table_name, columns:)))
}

fn parse_columns(
  table_name: String,
  body: String,
  enums: List(model.EnumDef),
) -> Result(List(model.Column), ParseError) {
  body
  |> split_top_level_commas
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
  |> list.try_fold([], fn(columns, entry) {
    use maybe_column <- result.try(parse_column(table_name, entry, enums))
    Ok(case maybe_column {
      Some(column) -> [column, ..columns]
      None -> columns
    })
  })
  |> result.map(list.reverse)
}

fn parse_column(
  table_name: String,
  entry: String,
  enums: List(model.EnumDef),
) -> Result(Option(model.Column), ParseError) {
  let tokens =
    entry
    |> string.split(" ")
    |> list.map(string.trim)
    |> list.filter(fn(token) { token != "" })

  case tokens {
    [] -> Ok(None)
    [first, ..rest] -> {
      let first_lower = string.lowercase(first)

      case is_table_constraint(first_lower) {
        True -> Ok(None)
        False -> {
          let name = trim_identifier(first)
          let type_tokens = take_type_tokens(rest, [])

          case type_tokens {
            [] ->
              Error(InvalidColumn(
                table: table_name,
                detail: "missing type for column " <> name,
              ))
            _ -> {
              let type_text = string.join(type_tokens, " ")
              let lowered = list.map(tokens, string.lowercase)
              let nullable = case
                contains_phrase(lowered, "not", "null")
                || list.contains(lowered, "primary")
              {
                True -> False
                False -> True
              }

              let scalar_type = case find_enum(type_text, enums) {
                Some(enum_name) -> model.EnumType(enum_name)
                None -> infer_scalar_type(type_text)
              }

              Ok(Some(model.Column(name:, scalar_type:, nullable:)))
            }
          }
        }
      }
    }
  }
}

fn split_top_level_commas(input: String) -> List(String) {
  split_top_level_commas_loop(input, 0, "", [])
}

fn split_top_level_commas_loop(
  remaining: String,
  depth: Int,
  current: String,
  acc: List(String),
) -> List(String) {
  case string.pop_grapheme(remaining) {
    Error(_) ->
      case string.trim(current) == "" {
        True -> list.reverse(acc)
        False -> list.reverse([string.trim(current), ..acc])
      }
    Ok(#(grapheme, rest)) ->
      case grapheme {
        "(" ->
          split_top_level_commas_loop(rest, depth + 1, current <> grapheme, acc)
        ")" ->
          split_top_level_commas_loop(rest, depth - 1, current <> grapheme, acc)
        "," ->
          case depth == 0 {
            True ->
              split_top_level_commas_loop(rest, depth, "", [
                string.trim(current),
                ..acc
              ])
            False ->
              split_top_level_commas_loop(rest, depth, current <> grapheme, acc)
          }
        _ -> split_top_level_commas_loop(rest, depth, current <> grapheme, acc)
      }
  }
}

fn take_type_tokens(tokens: List(String), acc: List(String)) -> List(String) {
  case tokens {
    [] -> list.reverse(acc)
    [token, ..rest] ->
      case is_column_constraint(string.lowercase(token)) {
        True -> list.reverse(acc)
        False -> take_type_tokens(rest, [token, ..acc])
      }
  }
}

fn infer_scalar_type(type_text: String) -> model.ScalarType {
  let lowered = string.lowercase(type_text)

  case string.contains(lowered, "int") || string.contains(lowered, "serial") {
    True -> model.IntType
    False ->
      case
        string.contains(lowered, "double")
        || string.contains(lowered, "real")
        || string.contains(lowered, "float")
        || string.contains(lowered, "numeric")
        || string.contains(lowered, "decimal")
      {
        True -> model.FloatType
        False ->
          case string.contains(lowered, "bool") {
            True -> model.BoolType
            False ->
              case
                string.contains(lowered, "bytea")
                || string.contains(lowered, "blob")
                || string.contains(lowered, "binary")
              {
                True -> model.BytesType
                False ->
                  case string.contains(lowered, "uuid") {
                    True -> model.UuidType
                    False ->
                      case
                        string.contains(lowered, "json")
                        || string.contains(lowered, "jsonb")
                      {
                        True -> model.JsonType
                        False ->
                          case
                            string.contains(lowered, "timestamp")
                            || string.contains(lowered, "datetime")
                          {
                            True -> model.DateTimeType
                            False ->
                              case string.contains(lowered, "date") {
                                True -> model.DateType
                                False ->
                                  case
                                    string.contains(lowered, "time")
                                    || string.contains(lowered, "timetz")
                                  {
                                    True -> model.TimeType
                                    False -> model.StringType
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

fn is_table_constraint(token: String) -> Bool {
  list.contains(["primary", "foreign", "unique", "constraint", "check"], token)
}

fn is_column_constraint(token: String) -> Bool {
  list.contains(
    [
      "not",
      "null",
      "primary",
      "unique",
      "default",
      "references",
      "check",
      "constraint",
      "generated",
      "collate",
    ],
    token,
  )
}

fn contains_phrase(tokens: List(String), first: String, second: String) -> Bool {
  case tokens {
    [] | [_] -> False
    [a, b, ..rest] ->
      case a == first && b == second {
        True -> True
        False -> contains_phrase([b, ..rest], first, second)
      }
  }
}

fn trim_identifier(identifier: String) -> String {
  identifier
  |> string.trim
  |> trim_identifier_quotes
  |> last_identifier_segment
  |> string.lowercase
}

fn trim_identifier_quotes(identifier: String) -> String {
  let length = string.length(identifier)

  case length >= 2 {
    False -> identifier
    True -> {
      let first = string.slice(identifier, 0, 1)
      let last = string.slice(identifier, length - 1, 1)

      let is_quoted =
        { first == "\"" && last == "\"" }
        || { first == "`" && last == "`" }
        || { first == "[" && last == "]" }

      case is_quoted {
        True -> string.slice(identifier, 1, length - 2)
        False -> identifier
      }
    }
  }
}

fn last_identifier_segment(identifier: String) -> String {
  identifier
  |> string.split(".")
  |> list.last
  |> result.unwrap(identifier)
}

fn find_enum(type_text: String, enums: List(model.EnumDef)) -> Option(String) {
  let lowered = string.lowercase(string.trim(type_text))

  case list.find(enums, fn(e) { e.name == lowered }) {
    Ok(e) -> Some(e.name)
    Error(_) -> None
  }
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    InvalidCreateTable(detail:) -> "Invalid CREATE TABLE statement: " <> detail
    InvalidColumn(table:, detail:) ->
      "Invalid column definition in table " <> table <> ": " <> detail
  }
}
