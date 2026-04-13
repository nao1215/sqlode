import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/context.{type AnalyzerContext}

pub type PlaceholderOccurrence {
  PlaceholderOccurrence(index: Int, token: String, default_name: String)
}

pub fn extract(
  ctx: AnalyzerContext,
  engine: model.Engine,
  sql: String,
) -> List(PlaceholderOccurrence) {
  let tokens = placeholder_tokens(ctx, engine, sql)
  build_occurrences(ctx, engine, tokens, 1, [])
}

pub fn unique(
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

pub fn placeholder_index_for_token(
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

pub fn sequential_placeholder(engine: model.Engine) -> Bool {
  case engine {
    model.PostgreSQL -> False
    model.MySQL | model.SQLite -> True
  }
}

pub fn is_placeholder_token(value: String) -> Bool {
  string.starts_with(value, "$")
  || string.starts_with(value, ":")
  || string.starts_with(value, "@")
  || string.starts_with(value, "?")
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
