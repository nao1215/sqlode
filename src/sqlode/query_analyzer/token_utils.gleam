import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/lexer

/// Extract all table names referenced in a token list (FROM, INTO, UPDATE, JOIN).
pub fn extract_table_names(tokens: List(lexer.Token)) -> List(String) {
  table_names_loop(tokens, [])
  |> list.unique
}

fn table_names_loop(
  tokens: List(lexer.Token),
  acc: List(String),
) -> List(String) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.Keyword("from"), lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      table_names_loop(remaining, acc)
    }
    [lexer.Keyword(kw), ..rest]
      if kw == "from" || kw == "into" || kw == "update"
    -> {
      let #(name, remaining) = read_table_name(rest)
      case name {
        Some(n) -> table_names_loop(remaining, [n, ..acc])
        None -> table_names_loop(rest, acc)
      }
    }
    [lexer.Keyword("join"), ..rest] -> {
      let #(name, remaining) = read_table_name(rest)
      case name {
        Some(n) -> table_names_loop(remaining, [n, ..acc])
        None -> table_names_loop(rest, acc)
      }
    }
    [_, ..rest] -> table_names_loop(rest, acc)
  }
}

/// Read a table name from the current token position, handling schema-qualified
/// names (schema.table) and subqueries in parentheses.
pub fn read_table_name(
  tokens: List(lexer.Token),
) -> #(Option(String), List(lexer.Token)) {
  case tokens {
    [lexer.Ident(_), lexer.Dot, lexer.Ident(name), ..rest] -> #(
      Some(string.lowercase(name)),
      rest,
    )
    [lexer.Ident(name), ..rest] -> #(Some(string.lowercase(name)), rest)
    [lexer.QuotedIdent(name), ..rest] -> #(Some(string.lowercase(name)), rest)
    [lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      #(None, remaining)
    }
    _ -> #(None, tokens)
  }
}

/// Skip tokens until all parentheses at the given depth are closed.
pub fn skip_parens(tokens: List(lexer.Token), depth: Int) -> List(lexer.Token) {
  case depth <= 0 {
    True -> tokens
    False ->
      case tokens {
        [] -> []
        [lexer.LParen, ..rest] -> skip_parens(rest, depth + 1)
        [lexer.RParen, ..rest] -> skip_parens(rest, depth - 1)
        [_, ..rest] -> skip_parens(rest, depth)
      }
  }
}
