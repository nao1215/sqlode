import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/lexer
import sqlode/naming
import sqlode/query_ir

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

/// Strip a leading `WITH [RECURSIVE] cte_defs` clause so downstream
/// passes see only the tokens of the main statement. Each CTE
/// definition lives inside parentheses so we skip them along with
/// the name / column-list preamble between commas. If the statement
/// does not begin with WITH, the tokens are returned unchanged.
///
/// This is the same strip that the column inferencer uses for
/// result-column scoping; exposing it here lets the parameter
/// inferencer reuse the identical boundary when it decides which
/// tables are visible to a top-level WHERE/ON predicate.
pub fn strip_leading_with(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword("with"), lexer.Keyword("recursive"), ..rest] ->
      skip_with_body(rest)
    [lexer.Keyword("with"), ..rest] -> skip_with_body(rest)
    _ -> tokens
  }
}

fn skip_with_body(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [] -> []
    [lexer.Keyword(kw), ..] as t
      if kw == "select" || kw == "insert" || kw == "update" || kw == "delete"
    -> t
    [lexer.LParen, ..rest] -> {
      let remaining = skip_parens(rest, 1)
      skip_with_body(remaining)
    }
    [_, ..rest] -> skip_with_body(rest)
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
    [lexer.Keyword("insert"), ..rest] ->
      case strip_insert_or_action(rest) {
        [lexer.Keyword("into"), ..after_into] ->
          parse_insert_after_into(after_into)
        _ -> find_insert_loop(rest)
      }
    [_, ..rest] -> find_insert_loop(rest)
  }
}

/// Strip a leading SQLite-specific `OR <conflict-action>` qualifier
/// from the token stream that follows `INSERT`. Returns the input
/// unchanged when the next token is not `OR`. The five conflict
/// actions per <https://www.sqlite.org/lang_insert.html> are
/// REPLACE, ROLLBACK, ABORT, FAIL, IGNORE — REPLACE and ROLLBACK
/// are reserved keywords, the other three lex as `Ident` tokens
/// (case-preserving). (#478)
pub fn strip_insert_or_action(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword("or"), action, ..rest] ->
      case is_insert_or_action_token(action) {
        True -> rest
        False -> tokens
      }
    _ -> tokens
  }
}

fn is_insert_or_action_token(token: lexer.Token) -> Bool {
  case token {
    lexer.Keyword("replace") -> True
    lexer.Keyword("rollback") -> True
    lexer.Ident(t) ->
      t == "ignore"
      || t == "IGNORE"
      || t == "Ignore"
      || t == "abort"
      || t == "ABORT"
      || t == "Abort"
      || t == "fail"
      || t == "FAIL"
      || t == "Fail"
    _ -> False
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

/// Find all `column op ANY|ALL|SOME (placeholder)` patterns. This
/// complements `find_in_patterns` for the PostgreSQL-style quantified
/// comparison syntax `t.id = ANY(sqlode.slice(team_ids))` used by
/// fixture 2 in Issue #393.
pub fn find_quantified_patterns(
  tokens: List(lexer.Token),
) -> List(EqualityMatch) {
  find_quantified_loop(tokens, [])
  |> list.reverse
}

fn find_quantified_loop(
  tokens: List(lexer.Token),
  acc: List(EqualityMatch),
) -> List(EqualityMatch) {
  case tokens {
    [] -> acc
    // table.col <op> ANY|ALL|SOME ( placeholder )
    [
      lexer.Ident(t),
      lexer.Dot,
      lexer.Ident(c),
      lexer.Operator(_op),
      lexer.Keyword(q),
      lexer.LParen,
      lexer.Placeholder(p),
      lexer.RParen,
      ..rest
    ]
      if q == "any" || q == "all" || q == "some"
    ->
      find_quantified_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: Some(string.lowercase(t)),
          placeholder: p,
        ),
        ..acc
      ])
    // col <op> ANY|ALL|SOME ( placeholder )
    [
      lexer.Ident(c),
      lexer.Operator(_op),
      lexer.Keyword(q),
      lexer.LParen,
      lexer.Placeholder(p),
      lexer.RParen,
      ..rest
    ]
      if q == "any" || q == "all" || q == "some"
    ->
      find_quantified_loop(rest, [
        EqualityMatch(
          column_name: naming.normalize_identifier(c),
          table_qualifier: None,
          placeholder: p,
        ),
        ..acc
      ])
    [_, ..rest] -> find_quantified_loop(rest, acc)
  }
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

// ============================================================
// Structured IR construction
// ============================================================

/// Build a `SqlStatement` from a token list. This function identifies the
/// statement kind and decomposes it into its major clauses. Sub-expressions
/// (WHERE predicates, etc.) remain as raw token lists — this is
/// intentionally a *thin* IR that avoids building a full expression AST.
pub fn structure_tokens(tokens: List(lexer.Token)) -> query_ir.SqlStatement {
  let stripped = strip_leading_cte(tokens)
  case stripped {
    [lexer.Keyword("select"), ..] -> structure_select(stripped)
    [lexer.Keyword("insert"), ..] -> structure_insert(stripped)
    [lexer.Keyword("update"), ..] -> structure_update(stripped)
    [lexer.Keyword("delete"), ..] -> structure_delete(stripped)
    _ -> query_ir.UnstructuredStatement(tokens: stripped)
  }
}

fn strip_leading_cte(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword("with"), ..rest] -> skip_cte_body(rest)
    _ -> tokens
  }
}

fn skip_cte_body(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [] -> []
    // When we hit a top-level SELECT/INSERT/UPDATE/DELETE after the CTE, stop
    [lexer.Keyword("select"), ..] as t -> t
    [lexer.Keyword("insert"), ..] as t -> t
    [lexer.Keyword("update"), ..] as t -> t
    [lexer.Keyword("delete"), ..] as t -> t
    [lexer.LParen, ..rest] -> {
      let after = skip_parens(rest, 1)
      skip_cte_body(after)
    }
    [_, ..rest] -> skip_cte_body(rest)
  }
}

// --- SELECT structuring ---

fn structure_select(tokens: List(lexer.Token)) -> query_ir.SqlStatement {
  let after_select = case tokens {
    [lexer.Keyword("select"), lexer.Keyword("distinct"), ..rest] -> rest
    [lexer.Keyword("select"), ..rest] -> rest
    _ -> tokens
  }

  let #(select_tokens, rest_after_select) =
    collect_until_keyword(after_select, [
      "from", "where", "group", "having", "order", "limit", "union", "intersect",
      "except",
    ])
  let select_items = parse_select_items(select_tokens)

  let #(from_items, joins, rest_after_from) =
    parse_from_clause(rest_after_select)

  let #(where_tokens, rest_after_where) =
    extract_clause(rest_after_from, "where", [
      "group", "having", "order", "limit", "union", "intersect", "except",
    ])
  let #(group_by_tokens, rest_after_group) =
    extract_clause(rest_after_where, "group", [
      "having", "order", "limit", "union", "intersect", "except",
    ])
  let #(having_tokens, rest_after_having) =
    extract_clause(rest_after_group, "having", [
      "order", "limit", "union", "intersect", "except",
    ])
  let #(order_by_tokens, rest_after_order) =
    extract_clause(rest_after_having, "order", [
      "limit", "union", "intersect", "except",
    ])
  let #(limit_tokens, _) =
    extract_clause(rest_after_order, "limit", ["union", "intersect", "except"])

  query_ir.SelectStatement(
    select_items:,
    from: from_items,
    joins:,
    where_tokens:,
    group_by_tokens:,
    having_tokens:,
    order_by_tokens:,
    limit_tokens:,
  )
}

fn parse_select_items(tokens: List(lexer.Token)) -> List(query_ir.SelectItem) {
  let groups = split_on_commas(tokens)
  list.map(groups, fn(group) {
    case group {
      [lexer.Operator("*")] -> query_ir.StarItem(table_prefix: None)
      [lexer.Ident(t), lexer.Dot, lexer.Operator("*")] ->
        query_ir.StarItem(table_prefix: Some(string.lowercase(t)))
      _ -> {
        let alias = extract_alias_from_item(group)
        query_ir.ExpressionItem(tokens: group, alias:)
      }
    }
  })
}

fn extract_alias_from_item(tokens: List(lexer.Token)) -> Option(String) {
  case list.reverse(tokens) {
    [lexer.Ident(name), lexer.Keyword("as"), ..] ->
      Some(naming.normalize_identifier(name))
    [lexer.QuotedIdent(name), lexer.Keyword("as"), ..] ->
      Some(naming.normalize_identifier(name))
    _ -> None
  }
}

fn parse_from_clause(
  tokens: List(lexer.Token),
) -> #(List(query_ir.FromItem), List(query_ir.JoinClause), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("from"), ..rest] -> {
      let #(from_tokens, after_from) =
        collect_until_keyword(rest, [
          "where", "group", "having", "order", "limit", "union", "intersect",
          "except", "join", "left", "right", "inner", "outer", "cross", "full",
          "natural", "lateral",
        ])
      let from_items = parse_from_items(from_tokens)
      let #(joins, after_joins) = parse_join_clauses(after_from)
      #(from_items, joins, after_joins)
    }
    _ -> #([], [], tokens)
  }
}

fn parse_from_items(tokens: List(lexer.Token)) -> List(query_ir.FromItem) {
  let groups = split_on_commas(tokens)
  list.filter_map(groups, fn(group) {
    case group {
      [lexer.Ident(name)] ->
        Ok(query_ir.TableRef(name: string.lowercase(name), alias: None))
      [lexer.QuotedIdent(name)] ->
        Ok(query_ir.TableRef(name: string.lowercase(name), alias: None))
      [lexer.Ident(_schema), lexer.Dot, lexer.Ident(name)] ->
        Ok(query_ir.TableRef(name: string.lowercase(name), alias: None))
      [lexer.Ident(name), lexer.Keyword("as"), lexer.Ident(a)] ->
        Ok(query_ir.TableRef(
          name: string.lowercase(name),
          alias: Some(string.lowercase(a)),
        ))
      [lexer.Ident(name), lexer.Ident(a)] ->
        Ok(query_ir.TableRef(
          name: string.lowercase(name),
          alias: Some(string.lowercase(a)),
        ))
      _ -> Error(Nil)
    }
  })
}

fn parse_join_clauses(
  tokens: List(lexer.Token),
) -> #(List(query_ir.JoinClause), List(lexer.Token)) {
  parse_joins_loop(tokens, [])
}

fn parse_joins_loop(
  tokens: List(lexer.Token),
  acc: List(query_ir.JoinClause),
) -> #(List(query_ir.JoinClause), List(lexer.Token)) {
  case tokens {
    // JOIN variants
    [lexer.Keyword(kw), ..rest]
      if kw == "join"
      || kw == "left"
      || kw == "right"
      || kw == "inner"
      || kw == "outer"
      || kw == "cross"
      || kw == "full"
      || kw == "natural"
    -> {
      let after_join_kw = skip_join_keywords(rest)
      case after_join_kw {
        [lexer.Keyword("join"), ..after_join] -> {
          let #(clause, remaining) = parse_single_join(after_join)
          case clause {
            Some(j) -> parse_joins_loop(remaining, [j, ..acc])
            None -> parse_joins_loop(remaining, acc)
          }
        }
        _ -> {
          let #(clause, remaining) = parse_single_join(after_join_kw)
          case clause {
            Some(j) -> parse_joins_loop(remaining, [j, ..acc])
            None -> parse_joins_loop(remaining, acc)
          }
        }
      }
    }
    _ -> #(list.reverse(acc), tokens)
  }
}

fn skip_join_keywords(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword(kw), ..rest]
      if kw == "outer"
      || kw == "inner"
      || kw == "cross"
      || kw == "natural"
      || kw == "left"
      || kw == "right"
      || kw == "full"
    -> skip_join_keywords(rest)
    _ -> tokens
  }
}

fn parse_single_join(
  tokens: List(lexer.Token),
) -> #(Option(query_ir.JoinClause), List(lexer.Token)) {
  let #(table_name_opt, rest) = read_table_name(tokens)
  case table_name_opt {
    None -> #(None, rest)
    Some(name) -> {
      let #(alias, rest2) = read_optional_alias(rest)
      let #(on_tokens, rest3) = case rest2 {
        [lexer.Keyword("on"), ..after_on] -> {
          let #(on_toks, after) =
            collect_until_keyword(after_on, [
              "join", "left", "right", "inner", "outer", "cross", "full",
              "natural", "where", "group", "having", "order", "limit", "union",
              "intersect", "except",
            ])
          #(Some(on_toks), after)
        }
        _ -> #(None, rest2)
      }
      #(Some(query_ir.JoinClause(table_name: name, alias:, on_tokens:)), rest3)
    }
  }
}

fn read_optional_alias(
  tokens: List(lexer.Token),
) -> #(Option(String), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("as"), lexer.Ident(a), ..rest] -> #(
      Some(string.lowercase(a)),
      rest,
    )
    [lexer.Keyword("as"), lexer.QuotedIdent(a), ..rest] -> #(
      Some(string.lowercase(a)),
      rest,
    )
    [lexer.Ident(a), ..rest]
      if a != "on"
      && a != "where"
      && a != "group"
      && a != "order"
      && a != "limit"
      && a != "join"
      && a != "left"
      && a != "right"
      && a != "inner"
    -> #(Some(string.lowercase(a)), rest)
    _ -> #(None, tokens)
  }
}

// --- INSERT structuring ---

fn structure_insert(tokens: List(lexer.Token)) -> query_ir.SqlStatement {
  case find_insert_parts(tokens) {
    Some(parts) -> {
      let returning = extract_returning_tokens(tokens)
      query_ir.InsertStatement(
        table_name: parts.table_name,
        columns: parts.columns,
        value_groups: parts.values,
        returning_tokens: returning,
      )
    }
    None -> query_ir.UnstructuredStatement(tokens:)
  }
}

// --- UPDATE structuring ---

fn structure_update(tokens: List(lexer.Token)) -> query_ir.SqlStatement {
  case tokens {
    [lexer.Keyword("update"), ..rest] -> {
      let #(table_name_opt, after_table) = read_table_name(rest)
      case table_name_opt {
        None -> query_ir.UnstructuredStatement(tokens:)
        Some(name) -> {
          let #(set_tokens, after_set) = case
            skip_to_keyword(after_table, "set")
          {
            Some(after_set_kw) ->
              collect_until_keyword(after_set_kw, ["where", "returning", "from"])
            None -> #([], after_table)
          }
          let #(where_tokens, _) =
            extract_clause(after_set, "where", ["returning"])
          let returning = extract_returning_tokens(tokens)
          query_ir.UpdateStatement(
            table_name: name,
            set_tokens:,
            where_tokens:,
            returning_tokens: returning,
          )
        }
      }
    }
    _ -> query_ir.UnstructuredStatement(tokens:)
  }
}

// --- DELETE structuring ---

fn structure_delete(tokens: List(lexer.Token)) -> query_ir.SqlStatement {
  case tokens {
    [lexer.Keyword("delete"), lexer.Keyword("from"), ..rest] -> {
      let #(table_name_opt, after_table) = read_table_name(rest)
      case table_name_opt {
        None -> query_ir.UnstructuredStatement(tokens:)
        Some(name) -> {
          let #(where_tokens, _after_where) =
            extract_clause(after_table, "where", ["returning"])
          let returning = extract_returning_tokens(tokens)
          query_ir.DeleteStatement(
            table_name: name,
            where_tokens:,
            returning_tokens: returning,
          )
        }
      }
    }
    _ -> query_ir.UnstructuredStatement(tokens:)
  }
}

// --- Clause extraction helpers ---

/// Collect tokens until one of the stop keywords is found at depth 0.
fn collect_until_keyword(
  tokens: List(lexer.Token),
  stop_keywords: List(String),
) -> #(List(lexer.Token), List(lexer.Token)) {
  collect_until_kw_loop(tokens, stop_keywords, 0, [])
}

fn collect_until_kw_loop(
  tokens: List(lexer.Token),
  stop_keywords: List(String),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case tokens {
    [] -> #(list.reverse(acc), [])
    [lexer.Keyword(kw), ..] if depth == 0 ->
      case list.contains(stop_keywords, kw) {
        True -> #(list.reverse(acc), tokens)
        False ->
          case tokens {
            [t, ..rest] ->
              collect_until_kw_loop(rest, stop_keywords, depth, [t, ..acc])
            _ -> #(list.reverse(acc), [])
          }
      }
    [lexer.LParen, ..rest] ->
      collect_until_kw_loop(rest, stop_keywords, depth + 1, [
        lexer.LParen,
        ..acc
      ])
    [lexer.RParen, ..rest] ->
      collect_until_kw_loop(rest, stop_keywords, depth - 1, [
        lexer.RParen,
        ..acc
      ])
    [t, ..rest] -> collect_until_kw_loop(rest, stop_keywords, depth, [t, ..acc])
  }
}

/// Extract a clause that starts with `keyword` and ends before any of `stop_keywords`.
fn extract_clause(
  tokens: List(lexer.Token),
  keyword: String,
  stop_keywords: List(String),
) -> #(Option(List(lexer.Token)), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword(kw), ..rest] if kw == keyword -> {
      // For GROUP BY / ORDER BY, also skip the "by" keyword
      let after_kw = case kw, rest {
        "group", [lexer.Keyword("by"), ..r] -> r
        "order", [lexer.Keyword("by"), ..r] -> r
        _, _ -> rest
      }
      let #(clause_tokens, remaining) =
        collect_until_keyword(after_kw, stop_keywords)
      case clause_tokens {
        [] -> #(None, remaining)
        _ -> #(Some(clause_tokens), remaining)
      }
    }
    _ -> #(None, tokens)
  }
}

fn skip_to_keyword(
  tokens: List(lexer.Token),
  keyword: String,
) -> Option(List(lexer.Token)) {
  case tokens {
    [] -> None
    [lexer.Keyword(kw), ..rest] if kw == keyword -> Some(rest)
    [_, ..rest] -> skip_to_keyword(rest, keyword)
  }
}

fn extract_returning_tokens(
  tokens: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case skip_to_keyword(tokens, "returning") {
    Some(after_returning) ->
      case after_returning {
        [] -> None
        toks -> Some(toks)
      }
    None -> None
  }
}
