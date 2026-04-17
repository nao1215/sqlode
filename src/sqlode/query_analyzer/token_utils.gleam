import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/lexer
import sqlode/naming

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
    // FROM (subquery) AS alias(...) — covers VALUES, derived tables,
    // and LATERAL subqueries. The alias names a virtual table that
    // extract_values_tables or extract_derived_tables is responsible
    // for registering in the catalog.
    [lexer.Keyword("from"), lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      case read_subquery_alias(remaining) {
        #(Some(n), after_alias) -> table_names_loop(after_alias, [n, ..acc])
        #(None, _) -> table_names_loop(remaining, acc)
      }
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
    // JOIN LATERAL (subquery) AS alias(...) — consume LATERAL before
    // the paren so the alias is picked up.
    [lexer.Keyword("join"), lexer.Keyword("lateral"), lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      case read_subquery_alias(remaining) {
        #(Some(n), after_alias) -> table_names_loop(after_alias, [n, ..acc])
        #(None, _) -> table_names_loop(remaining, acc)
      }
    }
    [lexer.Keyword("join"), lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      case read_subquery_alias(remaining) {
        #(Some(n), after_alias) -> table_names_loop(after_alias, [n, ..acc])
        #(None, _) -> table_names_loop(remaining, acc)
      }
    }
    // PostgreSQL comma-LATERAL: FROM t1, LATERAL (subquery) AS alias
    [lexer.Keyword("lateral"), lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      case read_subquery_alias(remaining) {
        #(Some(n), after_alias) -> table_names_loop(after_alias, [n, ..acc])
        #(None, _) -> table_names_loop(remaining, acc)
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

/// Read an optional AS followed by an identifier alias, optionally
/// followed by a parenthesised column list. Returns the alias and the
/// token stream positioned after the alias (and column list, if any).
pub fn read_subquery_alias(
  tokens: List(lexer.Token),
) -> #(Option(String), List(lexer.Token)) {
  let after_as = case tokens {
    [lexer.Keyword("as"), ..rest] -> rest
    _ -> tokens
  }
  case after_as {
    [lexer.Ident(name), lexer.LParen, ..rest_after_lp] -> {
      let #(_, after_cols) = collect_paren_contents(rest_after_lp)
      #(Some(string.lowercase(name)), after_cols)
    }
    [lexer.QuotedIdent(name), lexer.LParen, ..rest_after_lp] -> {
      let #(_, after_cols) = collect_paren_contents(rest_after_lp)
      #(Some(string.lowercase(name)), after_cols)
    }
    [lexer.Ident(name), ..rest] -> #(Some(string.lowercase(name)), rest)
    [lexer.QuotedIdent(name), ..rest] -> #(Some(string.lowercase(name)), rest)
    _ -> #(None, after_as)
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

// ============================================================
// Shared token utilities for token-first parsing (#342)
// ============================================================

/// Extract all placeholder token strings from a token list.
pub fn extract_placeholders(tokens: List(lexer.Token)) -> List(String) {
  list.filter_map(tokens, fn(token) {
    case token {
      lexer.Placeholder(p) -> Ok(p)
      _ -> Error(Nil)
    }
  })
}

/// Collect tokens inside the next parenthesized group.
/// Expects tokens starting right after the opening LParen.
/// Returns #(inner_tokens, remaining_tokens_after_RParen).
pub fn collect_paren_contents(
  tokens: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  collect_paren_loop(tokens, 1, [])
}

fn collect_paren_loop(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case depth <= 0 {
    True -> #(list.reverse(acc), tokens)
    False ->
      case tokens {
        [] -> #(list.reverse(acc), [])
        [lexer.LParen, ..rest] ->
          collect_paren_loop(rest, depth + 1, [lexer.LParen, ..acc])
        [lexer.RParen, ..rest] ->
          case depth == 1 {
            True -> #(list.reverse(acc), rest)
            False -> collect_paren_loop(rest, depth - 1, [lexer.RParen, ..acc])
          }
        [token, ..rest] -> collect_paren_loop(rest, depth, [token, ..acc])
      }
  }
}

/// Split tokens on top-level commas (depth 0).
pub fn split_on_commas(tokens: List(lexer.Token)) -> List(List(lexer.Token)) {
  split_commas_loop(tokens, 0, [], [])
}

fn split_commas_loop(
  tokens: List(lexer.Token),
  depth: Int,
  current: List(lexer.Token),
  acc: List(List(lexer.Token)),
) -> List(List(lexer.Token)) {
  case tokens {
    [] ->
      case current {
        [] -> list.reverse(acc)
        _ -> list.reverse([list.reverse(current), ..acc])
      }
    [lexer.Comma, ..rest] if depth == 0 ->
      case current {
        [] -> split_commas_loop(rest, 0, [], acc)
        _ -> split_commas_loop(rest, 0, [], [list.reverse(current), ..acc])
      }
    [lexer.LParen, ..rest] ->
      split_commas_loop(rest, depth + 1, [lexer.LParen, ..current], acc)
    [lexer.RParen, ..rest] ->
      split_commas_loop(rest, depth - 1, [lexer.RParen, ..current], acc)
    [token, ..rest] -> split_commas_loop(rest, depth, [token, ..current], acc)
  }
}

// ============================================================
// INSERT parsing helpers
// ============================================================

pub type InsertParts {
  InsertParts(
    table_name: String,
    columns: List(String),
    values: List(List(lexer.Token)),
  )
}

/// Find INSERT INTO table (columns) VALUES (values) structure in tokens.
pub fn find_insert_parts(tokens: List(lexer.Token)) -> Option(InsertParts) {
  find_insert_loop(tokens)
}

fn find_insert_loop(tokens: List(lexer.Token)) -> Option(InsertParts) {
  case tokens {
    [] -> None
    [lexer.Keyword("insert"), lexer.Keyword("into"), ..rest] ->
      parse_insert_after_into(rest)
    [_, ..rest] -> find_insert_loop(rest)
  }
}

fn parse_insert_after_into(tokens: List(lexer.Token)) -> Option(InsertParts) {
  // Read table name
  let #(table_name_opt, rest) = read_table_name(tokens)
  case table_name_opt {
    None -> None
    Some(table_name) ->
      case rest {
        [lexer.LParen, ..after_lparen] -> {
          // Collect column names
          let #(col_tokens, after_cols) = collect_paren_contents(after_lparen)
          let columns =
            split_on_commas(col_tokens)
            |> list.filter_map(fn(group) {
              case group {
                [lexer.Ident(name)] -> Ok(naming.normalize_identifier(name))
                [lexer.QuotedIdent(name)] ->
                  Ok(naming.normalize_identifier(name))
                _ -> Error(Nil)
              }
            })
          // Skip to VALUES
          case skip_to_values(after_cols) {
            None -> None
            Some(after_values_kw) ->
              case after_values_kw {
                [lexer.LParen, ..after_vlparen] -> {
                  let #(val_tokens, _rest) =
                    collect_paren_contents(after_vlparen)
                  let values = split_on_commas(val_tokens)
                  Some(InsertParts(table_name:, columns:, values:))
                }
                _ -> None
              }
          }
        }
        _ -> None
      }
  }
}

fn skip_to_values(tokens: List(lexer.Token)) -> Option(List(lexer.Token)) {
  case tokens {
    [] -> None
    [lexer.Keyword("values"), ..rest] -> Some(rest)
    [_, ..rest] -> skip_to_values(rest)
  }
}

// ============================================================
// Equality / comparison pattern helpers
// ============================================================

pub type EqualityMatch {
  EqualityMatch(
    column_name: String,
    table_qualifier: Option(String),
    placeholder: String,
  )
}

/// Find all column [op] placeholder patterns in tokens.
pub fn find_equality_patterns(tokens: List(lexer.Token)) -> List(EqualityMatch) {
  find_equality_loop(tokens, [])
  |> list.reverse
}

fn find_equality_loop(
  tokens: List(lexer.Token),
  acc: List(EqualityMatch),
) -> List(EqualityMatch) {
  case tokens {
    [] -> acc

    // table.column op placeholder (comparison operators)
    [
      lexer.Ident(t),
      lexer.Dot,
      lexer.Ident(c),
      lexer.Operator(op),
      lexer.Placeholder(p),
      ..rest
    ]
      if op == "="
      || op == "!="
      || op == "<>"
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: Some(string.lowercase(t)),
          placeholder: p,
        ),
        ..acc
      ])

    [
      lexer.Ident(t),
      lexer.Dot,
      lexer.QuotedIdent(c),
      lexer.Operator(op),
      lexer.Placeholder(p),
      ..rest
    ]
      if op == "="
      || op == "!="
      || op == "<>"
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: Some(string.lowercase(t)),
          placeholder: p,
        ),
        ..acc
      ])

    // column op placeholder
    [lexer.Ident(c), lexer.Operator(op), lexer.Placeholder(p), ..rest]
      if op == "="
      || op == "!="
      || op == "<>"
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])

    [lexer.QuotedIdent(c), lexer.Operator(op), lexer.Placeholder(p), ..rest]
      if op == "="
      || op == "!="
      || op == "<>"
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])

    // table.column LIKE/ILIKE placeholder
    [
      lexer.Ident(t),
      lexer.Dot,
      lexer.Ident(c),
      lexer.Keyword(kw),
      lexer.Placeholder(p),
      ..rest
    ]
      if kw == "like" || kw == "ilike"
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: Some(string.lowercase(t)),
          placeholder: p,
        ),
        ..acc
      ])

    // column LIKE/ILIKE placeholder
    [lexer.Ident(c), lexer.Keyword(kw), lexer.Placeholder(p), ..rest]
      if kw == "like" || kw == "ilike"
    ->
      find_equality_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])

    [_, ..rest] -> find_equality_loop(rest, acc)
  }
}

// ============================================================
// IN clause pattern helpers
// ============================================================

/// Find all column IN (placeholder) patterns in tokens.
pub fn find_in_patterns(tokens: List(lexer.Token)) -> List(EqualityMatch) {
  find_in_loop(tokens, [])
  |> list.reverse
}

fn find_in_loop(
  tokens: List(lexer.Token),
  acc: List(EqualityMatch),
) -> List(EqualityMatch) {
  case tokens {
    [] -> acc

    // table.column IN (placeholder)
    [
      lexer.Ident(t),
      lexer.Dot,
      lexer.Ident(c),
      lexer.Keyword("in"),
      lexer.LParen,
      lexer.Placeholder(p),
      lexer.RParen,
      ..rest
    ] ->
      find_in_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: Some(string.lowercase(t)),
          placeholder: p,
        ),
        ..acc
      ])

    // column IN (placeholder)
    [
      lexer.Ident(c),
      lexer.Keyword("in"),
      lexer.LParen,
      lexer.Placeholder(p),
      lexer.RParen,
      ..rest
    ] ->
      find_in_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])

    [
      lexer.QuotedIdent(c),
      lexer.Keyword("in"),
      lexer.LParen,
      lexer.Placeholder(p),
      lexer.RParen,
      ..rest
    ] ->
      find_in_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])

    [_, ..rest] -> find_in_loop(rest, acc)
  }
}

// ============================================================
// Type cast helpers (PostgreSQL $N::type)
// ============================================================

pub type TypeCast {
  TypeCast(placeholder: String, cast_type: String)
}

/// Find all $N::type patterns in tokens (PostgreSQL only).
pub fn find_type_casts(tokens: List(lexer.Token)) -> List(TypeCast) {
  find_type_cast_loop(tokens, [])
  |> list.reverse
}

fn find_type_cast_loop(
  tokens: List(lexer.Token),
  acc: List(TypeCast),
) -> List(TypeCast) {
  case tokens {
    [] -> acc

    // $N::type_name
    [lexer.Placeholder(p), lexer.Operator("::"), lexer.Ident(t), ..rest] ->
      find_type_cast_loop(rest, [
        TypeCast(placeholder: p, cast_type: string.lowercase(t)),
        ..acc
      ])

    // $N::keyword (e.g. $1::int where int is a keyword)
    [lexer.Placeholder(p), lexer.Operator("::"), lexer.Keyword(t), ..rest] ->
      find_type_cast_loop(rest, [TypeCast(placeholder: p, cast_type: t), ..acc])

    [_, ..rest] -> find_type_cast_loop(rest, acc)
  }
}

/// Parse a placeholder string like "$3" into its integer index.
pub fn parse_placeholder_index(placeholder: String) -> Result(Int, Nil) {
  placeholder
  |> string.replace("$", "")
  |> int.parse
  |> option.from_result
  |> option.to_result(Nil)
}

// ============================================================
// SET clause pattern helpers (UPDATE ... SET col = placeholder)
// ============================================================

/// Find all column = placeholder patterns in SET clauses.
pub fn find_set_patterns(tokens: List(lexer.Token)) -> List(EqualityMatch) {
  find_set_clause(tokens, [])
  |> list.reverse
}

fn find_set_clause(
  tokens: List(lexer.Token),
  acc: List(EqualityMatch),
) -> List(EqualityMatch) {
  case tokens {
    [] -> acc
    [lexer.Keyword("set"), ..rest] -> scan_set_assignments(rest, acc)
    [_, ..rest] -> find_set_clause(rest, acc)
  }
}

fn scan_set_assignments(
  tokens: List(lexer.Token),
  acc: List(EqualityMatch),
) -> List(EqualityMatch) {
  case tokens {
    [] -> acc
    // Stop at WHERE or other clauses
    [lexer.Keyword(kw), ..]
      if kw == "where" || kw == "returning" || kw == "from"
    -> acc
    // column = placeholder
    [lexer.Ident(c), lexer.Operator("="), lexer.Placeholder(p), ..rest] ->
      scan_set_assignments(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])
    [lexer.QuotedIdent(c), lexer.Operator("="), lexer.Placeholder(p), ..rest] ->
      scan_set_assignments(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])
    [_, ..rest] -> scan_set_assignments(rest, acc)
  }
}
