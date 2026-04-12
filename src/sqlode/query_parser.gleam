import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import sqlode/model
import sqlode/naming

pub type ParseError {
  InvalidAnnotation(path: String, line: Int, detail: String)
  MissingSql(path: String, line: Int, name: String)
}

type PendingQuery {
  PendingQuery(
    name: String,
    function_name: String,
    command: model.QueryCommand,
    start_line: Int,
    body_rev: List(String),
  )
}

pub fn parse_file(
  path: String,
  engine: model.Engine,
  content: String,
) -> Result(List(model.ParsedQuery), ParseError) {
  parse_lines(string.split(content, "\n"), path, engine, 1, None, [])
  |> result.map(list.reverse)
}

fn parse_lines(
  lines: List(String),
  path: String,
  engine: model.Engine,
  line_number: Int,
  pending: Option(PendingQuery),
  parsed_rev: List(model.ParsedQuery),
) -> Result(List(model.ParsedQuery), ParseError) {
  case lines {
    [] -> finalize_pending(pending, path, engine, parsed_rev)
    [line, ..rest] -> {
      let trimmed = string.trim(line)

      case parse_annotation(trimmed, path, line_number) {
        Ok(Some(next_pending)) -> {
          use parsed_rev <- result.try(finalize_pending(
            pending,
            path,
            engine,
            parsed_rev,
          ))

          parse_lines(
            rest,
            path,
            engine,
            line_number + 1,
            Some(next_pending),
            parsed_rev,
          )
        }
        Ok(None) -> {
          let pending = case pending {
            Some(PendingQuery(
              name:,
              function_name:,
              command:,
              start_line:,
              body_rev:,
            )) ->
              Some(
                PendingQuery(
                  name:,
                  function_name:,
                  command:,
                  start_line:,
                  body_rev: [line, ..body_rev],
                ),
              )
            None -> None
          }

          parse_lines(rest, path, engine, line_number + 1, pending, parsed_rev)
        }
        Error(error) -> Error(error)
      }
    }
  }
}

fn finalize_pending(
  pending: Option(PendingQuery),
  path: String,
  engine: model.Engine,
  parsed_rev: List(model.ParsedQuery),
) -> Result(List(model.ParsedQuery), ParseError) {
  case pending {
    None -> Ok(parsed_rev)
    Some(PendingQuery(name:, function_name:, command:, start_line:, body_rev:)) -> {
      let sql =
        body_rev
        |> list.reverse
        |> string.join("\n")
        |> string.trim

      case sql == "" {
        True -> Error(MissingSql(path:, line: start_line, name:))
        False ->
          Ok([
            model.ParsedQuery(
              name:,
              function_name:,
              command:,
              sql:,
              source_path: path,
              param_count: count_parameters(engine, sql),
            ),
            ..parsed_rev
          ])
      }
    }
  }
}

fn parse_annotation(
  line: String,
  path: String,
  line_number: Int,
) -> Result(Option(PendingQuery), ParseError) {
  case string.starts_with(line, "-- name:") {
    False -> Ok(None)
    True -> {
      let rest =
        line
        |> string.replace("-- name:", "")
        |> string.trim

      let parts =
        string.split(rest, " ")
        |> list.map(string.trim)
        |> list.filter(fn(part) { part != "" })

      case parts {
        [name, command_text] -> {
          use command <- result.try(
            model.parse_query_command(command_text)
            |> result.map_error(fn(detail) {
              InvalidAnnotation(path:, line: line_number, detail:)
            }),
          )

          Ok(
            Some(
              PendingQuery(
                name:,
                function_name: naming.to_snake_case(name),
                command:,
                start_line: line_number,
                body_rev: [],
              ),
            ),
          )
        }
        _ ->
          Error(InvalidAnnotation(
            path:,
            line: line_number,
            detail: "expected '-- name: <Name> <command>'",
          ))
      }
    }
  }
}

fn count_parameters(engine: model.Engine, sql: String) -> Int {
  case engine {
    model.PostgreSQL -> count_postgresql_parameters(sql)
    model.MySQL -> count_question_mark_parameters(sql)
    model.SQLite -> count_sqlite_parameters(sql)
  }
}

fn count_postgresql_parameters(sql: String) -> Int {
  let assert Ok(re) = regexp.from_string("\\$([0-9]+)")

  regexp.scan(re, sql)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(index_text)] -> int.parse(index_text)
      _ -> Error(Nil)
    }
  })
  |> list.fold(0, fn(max_index, value) {
    case value > max_index {
      True -> value
      False -> max_index
    }
  })
}

fn count_question_mark_parameters(sql: String) -> Int {
  sql
  |> string.split("?")
  |> list.length
  |> fn(count) { count - 1 }
}

fn count_sqlite_parameters(sql: String) -> Int {
  let assert Ok(re) =
    regexp.from_string(
      "(\\?[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )

  regexp.scan(re, sql)
  |> list.length
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    InvalidAnnotation(path:, line:, detail:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": invalid query annotation: "
      <> detail
    MissingSql(path:, line:, name:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": query "
      <> name
      <> " is missing SQL body"
  }
}
