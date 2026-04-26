//// Recursive-descent parser that turns a list of SQL tokens into the
//// expression-aware IR (`query_ir.Expr` / `query_ir.SelectCore` /
//// `query_ir.Stmt`).
////
//// The parser is deliberately permissive: it models the SQL subset
//// sqlode needs to reason about (the constructs exercised by the
//// fixtures in `test/fixtures/complex_sql/`) and falls back to
//// `query_ir.RawExpr` / `query_ir.UnstructuredStmt` with an explicit
//// `reason` string when it hits a construct it does not understand.
//// The downstream analyzer surfaces these as
//// `AnalysisError.UnsupportedExpression`, so "silent fallback to
//// StringType" never happens — every gap is tied to a concrete IR
//// node an operator can point at.
////
//// Every public parsing entry takes an `engine: model.Engine` parameter
//// so MySQL-only constructs (`ON DUPLICATE KEY UPDATE`,
//// `LIMIT offset, count`) can be recognised without polluting the
//// PostgreSQL / SQLite paths. The engine is threaded through every
//// internal helper that (directly or transitively) parses another
//// expression, select core, or statement. Pure token-shape helpers
//// (paren collection, comma splitting, keyword scanning, etc.) do not
//// receive it — they are dialect-agnostic.
////
//// Precedence roughly follows PostgreSQL's operator table:
////
////   1. OR
////   2. AND
////   3. NOT
////   4. IS [NOT] NULL/TRUE/FALSE, IS [NOT] DISTINCT FROM
////   5. =, <>, !=, <, >, <=, >=, LIKE, ILIKE, IN, BETWEEN, SIMILAR TO,
////      @>, <@, ?|, ?&, &&
////   6. +, -, ||, JSON ops (->, ->>, #>, #>>)
////   7. *, /, %
////   8. unary -, +
////   9. ::type cast
////  10. function calls / atoms

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/token_utils
import sqlode/query_ir

/// Parse a full statement from its token list. Never fails; unknown
/// constructs surface as `UnstructuredStmt(reason, tokens)` with the
/// raw tokens preserved for legacy passes and the reason string
/// bubbled up to analyzer diagnostics.
pub fn parse_stmt(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Stmt {
  let #(ctes, recursive, after_ctes) = parse_with_clause(tokens, engine)
  case after_ctes {
    [lexer.Keyword("select"), ..] -> {
      let #(core, _rest) = parse_select_core(after_ctes, engine)
      query_ir.SelectStmt(ctes: attach_recursive(ctes, recursive), core: core)
    }
    [lexer.Keyword("insert"), ..rest] ->
      parse_insert_body(attach_recursive(ctes, recursive), rest, engine)
    [lexer.Keyword("update"), ..rest] ->
      parse_update_body(attach_recursive(ctes, recursive), rest, engine)
    [lexer.Keyword("delete"), ..rest] ->
      parse_delete_body(attach_recursive(ctes, recursive), rest, engine)
    _ ->
      query_ir.UnstructuredStmt(
        reason: "unrecognised top-level statement",
        tokens: tokens,
      )
  }
}

fn attach_recursive(
  ctes: List(query_ir.CteDef),
  recursive: Bool,
) -> List(query_ir.CteDef) {
  case recursive {
    False -> ctes
    True ->
      list.map(ctes, fn(cte) {
        query_ir.CteDef(
          name: cte.name,
          columns: cte.columns,
          body: cte.body,
          recursive: True,
        )
      })
  }
}

// ============================================================
// WITH-clause parsing
// ============================================================

fn parse_with_clause(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(List(query_ir.CteDef), Bool, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("with"), lexer.Keyword("recursive"), ..rest] -> {
      let #(ctes, remaining) = parse_cte_list(rest, [], engine)
      #(ctes, True, remaining)
    }
    [lexer.Keyword("with"), ..rest] -> {
      let #(ctes, remaining) = parse_cte_list(rest, [], engine)
      #(ctes, False, remaining)
    }
    _ -> #([], False, tokens)
  }
}

fn parse_cte_list(
  tokens: List(lexer.Token),
  acc: List(query_ir.CteDef),
  engine: model.Engine,
) -> #(List(query_ir.CteDef), List(lexer.Token)) {
  case parse_single_cte(tokens, engine) {
    Some(#(cte, after)) ->
      case after {
        [lexer.Comma, ..more] -> parse_cte_list(more, [cte, ..acc], engine)
        _ -> #(list.reverse([cte, ..acc]), after)
      }
    None -> #(list.reverse(acc), tokens)
  }
}

fn parse_single_cte(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> Option(#(query_ir.CteDef, List(lexer.Token))) {
  case tokens {
    [lexer.Ident(name), ..after_name] ->
      parse_cte_after_name(name, after_name, engine)
    [lexer.QuotedIdent(name), ..after_name] ->
      parse_cte_after_name(name, after_name, engine)
    _ -> None
  }
}

fn parse_cte_after_name(
  name: String,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> Option(#(query_ir.CteDef, List(lexer.Token))) {
  let #(columns, after_cols) = case tokens {
    [lexer.LParen, ..after_lp] -> {
      let #(inside, after) = collect_parens(after_lp)
      #(parse_ident_list(inside), after)
    }
    _ -> #([], tokens)
  }
  case after_cols {
    [lexer.Keyword("as"), lexer.LParen, ..after_as_lp] -> {
      let #(inner, after) = collect_parens(after_as_lp)
      let body = parse_stmt(inner, engine)
      Some(#(
        query_ir.CteDef(
          name: string.lowercase(name),
          columns: columns,
          body: body,
          recursive: False,
        ),
        after,
      ))
    }
    _ -> None
  }
}

fn parse_ident_list(tokens: List(lexer.Token)) -> List(String) {
  tokens
  |> split_on_top_commas()
  |> list.filter_map(fn(group) {
    case group {
      [lexer.Ident(n)] -> Ok(string.lowercase(n))
      [lexer.QuotedIdent(n)] -> Ok(string.lowercase(n))
      _ -> Error(Nil)
    }
  })
}

// ============================================================
// SELECT parsing
// ============================================================

pub fn parse_select_core(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.SelectCore, List(lexer.Token)) {
  let #(distinct, after_distinct) = case tokens {
    [lexer.Keyword("select"), lexer.Keyword("distinct"), ..rest] -> #(
      True,
      rest,
    )
    [lexer.Keyword("select"), ..rest] -> #(False, rest)
    _ -> #(False, tokens)
  }
  let #(select_tokens, rest_after_select) =
    collect_until_keyword(after_distinct, [
      "from", "where", "group", "having", "order", "limit", "offset", "union",
      "intersect", "except", "window",
    ])
  let items = parse_select_items(select_tokens, engine)
  let #(from_list, rest_after_from) = case rest_after_select {
    [lexer.Keyword("from"), ..rest] -> parse_from_clause(rest, engine)
    _ -> #([], rest_after_select)
  }
  let #(where_expr, rest_after_where) = case rest_after_from {
    [lexer.Keyword("where"), ..rest] -> {
      let #(where_toks, after) =
        collect_until_keyword(rest, [
          "group", "having", "order", "limit", "offset", "union", "intersect",
          "except", "window",
        ])
      #(Some(parse_expr(where_toks, engine)), after)
    }
    _ -> #(None, rest_after_from)
  }
  let #(group_by, rest_after_group) = case rest_after_where {
    [lexer.Keyword("group"), lexer.Keyword("by"), ..rest] -> {
      let #(gb_toks, after) =
        collect_until_keyword(rest, [
          "having", "order", "limit", "offset", "union", "intersect", "except",
          "window",
        ])
      #(parse_expr_list(gb_toks, engine), after)
    }
    _ -> #([], rest_after_where)
  }
  let #(having_expr, rest_after_having) = case rest_after_group {
    [lexer.Keyword("having"), ..rest] -> {
      let #(h_toks, after) =
        collect_until_keyword(rest, [
          "order", "limit", "offset", "union", "intersect", "except", "window",
        ])
      #(Some(parse_expr(h_toks, engine)), after)
    }
    _ -> #(None, rest_after_group)
  }
  let rest_after_window = case rest_after_having {
    [lexer.Keyword("window"), ..rest] -> {
      let #(_, after) =
        collect_until_keyword(rest, [
          "order", "limit", "offset", "union", "intersect", "except",
        ])
      after
    }
    _ -> rest_after_having
  }
  let #(order_by, rest_after_order) = case rest_after_window {
    [lexer.Keyword("order"), lexer.Keyword("by"), ..rest] -> {
      let #(o_toks, after) =
        collect_until_keyword(rest, [
          "limit", "offset", "union", "intersect", "except",
        ])
      #(parse_order_keys(o_toks, engine), after)
    }
    _ -> #([], rest_after_window)
  }
  // LIMIT handling. MySQL additionally supports the two-argument form
  // `LIMIT offset, count` which assigns in the opposite order from
  // PostgreSQL's `LIMIT count OFFSET offset`. For MySQL we split the
  // collected LIMIT tokens on a top-level comma and populate
  // `offset` / `limit` accordingly; if no comma is present the single
  // expression is a plain count, matching the other dialects.
  let #(limit, offset_from_limit, rest_after_limit) = case rest_after_order {
    [lexer.Keyword("limit"), ..rest] -> {
      let #(l_toks, after) =
        collect_until_keyword(rest, ["offset", "union", "intersect", "except"])
      case engine {
        model.MySQL -> {
          case split_on_top_commas(l_toks) {
            [offset_toks, count_toks] -> {
              // MySQL `LIMIT a, b` means offset=a, count=b — the
              // OPPOSITE assignment from `LIMIT a OFFSET b`.
              #(
                Some(parse_expr(count_toks, engine)),
                Some(parse_expr(offset_toks, engine)),
                after,
              )
            }
            _ -> #(Some(parse_expr(l_toks, engine)), None, after)
          }
        }
        _ -> #(Some(parse_expr(l_toks, engine)), None, after)
      }
    }
    _ -> #(None, None, rest_after_order)
  }
  let #(offset, rest_after_offset) = case rest_after_limit {
    [lexer.Keyword("offset"), ..rest] -> {
      let #(o_toks, after) =
        collect_until_keyword(rest, ["union", "intersect", "except"])
      #(Some(parse_expr(o_toks, engine)), after)
    }
    _ -> #(offset_from_limit, rest_after_limit)
  }
  let #(set_op, remaining) = parse_set_op(rest_after_offset, engine)
  #(
    query_ir.SelectCore(
      distinct: distinct,
      select_items: items,
      from: from_list,
      where_: where_expr,
      group_by: group_by,
      having: having_expr,
      order_by: order_by,
      limit: limit,
      offset: offset,
      set_op: set_op,
    ),
    remaining,
  )
}

fn parse_set_op(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(Option(query_ir.SetOp), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword(kw), ..rest]
      if kw == "union" || kw == "intersect" || kw == "except"
    -> {
      let #(all, rest2) = case rest {
        [lexer.Keyword("all"), ..more] -> #(True, more)
        _ -> #(False, rest)
      }
      let #(core, after) = parse_select_core(rest2, engine)
      let kind = case kw {
        "union" -> query_ir.Union
        "intersect" -> query_ir.Intersect
        _ -> query_ir.Except
      }
      #(Some(query_ir.SetOp(kind: kind, all: all, right: core)), after)
    }
    _ -> #(None, tokens)
  }
}

fn parse_order_keys(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> List(query_ir.OrderKey) {
  tokens
  |> split_on_top_commas()
  |> list.map(fn(group) { parse_order_key(group, engine) })
}

fn parse_order_key(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.OrderKey {
  let reversed = list.reverse(tokens)
  let #(nulls, reversed2) = case reversed {
    [lexer.Keyword("first"), lexer.Keyword("nulls"), ..rest] -> #(
      Some(query_ir.NullsFirst),
      rest,
    )
    [lexer.Keyword("last"), lexer.Keyword("nulls"), ..rest] -> #(
      Some(query_ir.NullsLast),
      rest,
    )
    _ -> #(None, reversed)
  }
  let #(descending, reversed3) = case reversed2 {
    [lexer.Keyword("desc"), ..rest] -> #(True, rest)
    [lexer.Keyword("asc"), ..rest] -> #(False, rest)
    _ -> #(False, reversed2)
  }
  let expr_tokens = list.reverse(reversed3)
  query_ir.OrderKey(
    expr: parse_expr(expr_tokens, engine),
    descending: descending,
    nulls: nulls,
  )
}

// ============================================================
// SELECT items
// ============================================================

fn parse_select_items(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> List(query_ir.SelectItemEx) {
  tokens
  |> split_on_top_commas()
  |> list.map(fn(group) { parse_select_item(group, engine) })
}

fn parse_select_item(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.SelectItemEx {
  case tokens {
    [lexer.Operator("*")] -> query_ir.StarEx(table_prefix: None)
    [lexer.Star] -> query_ir.StarEx(table_prefix: None)
    [lexer.Ident(t), lexer.Dot, lexer.Operator("*")] ->
      query_ir.StarEx(table_prefix: Some(string.lowercase(t)))
    [lexer.Ident(t), lexer.Dot, lexer.Star] ->
      query_ir.StarEx(table_prefix: Some(string.lowercase(t)))
    _ -> {
      let #(expr_tokens, alias) = split_trailing_alias(tokens)
      query_ir.ExprItem(expr: parse_expr(expr_tokens, engine), alias: alias)
    }
  }
}

fn split_trailing_alias(
  tokens: List(lexer.Token),
) -> #(List(lexer.Token), Option(String)) {
  case list.reverse(tokens) {
    [lexer.Ident(name), lexer.Keyword("as"), ..rest] -> #(
      list.reverse(rest),
      Some(naming.normalize_identifier(name)),
    )
    [lexer.QuotedIdent(name), lexer.Keyword("as"), ..rest] -> #(
      list.reverse(rest),
      Some(naming.normalize_identifier(name)),
    )
    // `expr alias` (no AS) — only accept this when the prior token
    // clearly ends an expression (ident / paren / literal), to avoid
    // misreading `SELECT tier` as `SELECT <no-expr> tier`.
    [lexer.Ident(name), prev, ..rest] ->
      case is_expr_end(prev) {
        True -> #(
          list.reverse([prev, ..rest]),
          Some(naming.normalize_identifier(name)),
        )
        False -> #(tokens, None)
      }
    _ -> #(tokens, None)
  }
}

fn is_expr_end(token: lexer.Token) -> Bool {
  case token {
    lexer.RParen -> True
    lexer.Ident(_) -> True
    lexer.QuotedIdent(_) -> True
    lexer.StringLit(_) -> True
    lexer.NumberLit(_) -> True
    lexer.Placeholder(_) -> True
    lexer.Star -> True
    _ -> False
  }
}

// ============================================================
// FROM / JOIN
// ============================================================

fn parse_from_clause(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(List(query_ir.FromItemEx), List(lexer.Token)) {
  let #(items_tokens, rest) =
    collect_until_keyword(tokens, [
      "where", "group", "having", "order", "limit", "offset", "union",
      "intersect", "except", "window", "returning",
    ])
  let groups = split_on_top_commas(items_tokens)
  let from_items =
    list.map(groups, fn(group) { parse_from_element(group, engine) })
  #(from_items, rest)
}

fn parse_from_element(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.FromItemEx {
  let #(first, after_first) = parse_primary_from(tokens, engine)
  parse_join_tail(first, after_first, engine)
}

fn parse_primary_from(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.FromItemEx, List(lexer.Token)) {
  case tokens {
    [lexer.LParen, lexer.Keyword("values"), ..rest] -> {
      let #(_, after) = collect_parens([lexer.Keyword("values"), ..rest])
      let #(body, _) = collect_parens([lexer.Keyword("values"), ..rest])
      parse_values_from_body(body, after, engine)
    }
    [lexer.LParen, lexer.Keyword("select"), ..] -> {
      let #(inner, after_rp) = collect_parens(drop_first(tokens))
      let #(core, _) = parse_select_core(inner, engine)
      parse_subquery_alias(core, after_rp, False)
    }
    [lexer.LParen, lexer.Keyword("with"), ..] -> {
      let #(inner, after_rp) = collect_parens(drop_first(tokens))
      let stmt = parse_stmt(inner, engine)
      let core = case stmt {
        query_ir.SelectStmt(core: c, ..) -> c
        _ -> empty_core()
      }
      parse_subquery_alias(core, after_rp, False)
    }
    [lexer.Keyword("lateral"), lexer.LParen, lexer.Keyword("select"), ..] -> {
      let #(inner, after_rp) = collect_parens(drop_first(drop_first(tokens)))
      let #(core, _) = parse_select_core(inner, engine)
      parse_subquery_alias(core, after_rp, True)
    }
    [lexer.Ident(_), lexer.Dot, lexer.Ident(name), ..rest] -> {
      let #(alias, rest2) = parse_optional_alias(rest)
      #(query_ir.FromTable(name: string.lowercase(name), alias: alias), rest2)
    }
    [lexer.Ident(name), ..rest] -> {
      let #(alias, rest2) = parse_optional_alias(rest)
      #(query_ir.FromTable(name: string.lowercase(name), alias: alias), rest2)
    }
    [lexer.QuotedIdent(name), ..rest] -> {
      let #(alias, rest2) = parse_optional_alias(rest)
      #(query_ir.FromTable(name: string.lowercase(name), alias: alias), rest2)
    }
    _ -> #(query_ir.FromTable(name: "", alias: None), tokens)
  }
}

fn parse_values_from_body(
  body: List(lexer.Token),
  after: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.FromItemEx, List(lexer.Token)) {
  let rows = parse_values_rows(body, engine)
  let #(alias_opt, col_aliases, rest) = parse_aliased_column_list(after)
  let alias = option.unwrap(alias_opt, "")
  #(
    query_ir.FromValues(rows: rows, alias: alias, column_aliases: col_aliases),
    rest,
  )
}

fn parse_values_rows(
  body: List(lexer.Token),
  engine: model.Engine,
) -> List(List(query_ir.Expr)) {
  case body {
    [lexer.Keyword("values"), ..rest] -> collect_values_rows(rest, [], engine)
    _ -> []
  }
}

fn collect_values_rows(
  tokens: List(lexer.Token),
  acc: List(List(query_ir.Expr)),
  engine: model.Engine,
) -> List(List(query_ir.Expr)) {
  case tokens {
    [lexer.LParen, ..rest] -> {
      let #(inner, after) = collect_parens(rest)
      let row =
        list.map(split_on_top_commas(inner), fn(group) {
          parse_expr(group, engine)
        })
      case after {
        [lexer.Comma, ..more] -> collect_values_rows(more, [row, ..acc], engine)
        _ -> list.reverse([row, ..acc])
      }
    }
    _ -> list.reverse(acc)
  }
}

fn parse_subquery_alias(
  core: query_ir.SelectCore,
  after: List(lexer.Token),
  lateral: Bool,
) -> #(query_ir.FromItemEx, List(lexer.Token)) {
  let #(alias_opt, col_aliases, rest) = parse_aliased_column_list(after)
  let alias = option.unwrap(alias_opt, "")
  let item =
    query_ir.FromSubquery(core: core, alias: alias, column_aliases: col_aliases)
  case lateral {
    True -> #(
      query_ir.FromJoin(
        left: query_ir.FromTable(name: "", alias: None),
        right: item,
        kind: query_ir.CrossJoin,
        on: query_ir.JoinNoCondition,
        lateral: True,
      ),
      rest,
    )
    False -> #(item, rest)
  }
}

fn parse_aliased_column_list(
  tokens: List(lexer.Token),
) -> #(Option(String), List(String), List(lexer.Token)) {
  let after_as = case tokens {
    [lexer.Keyword("as"), ..rest] -> rest
    _ -> tokens
  }
  case after_as {
    [lexer.Ident(alias), lexer.LParen, ..after_lp] -> {
      let #(cols, after) = collect_parens(after_lp)
      #(Some(string.lowercase(alias)), parse_ident_list(cols), after)
    }
    [lexer.QuotedIdent(alias), lexer.LParen, ..after_lp] -> {
      let #(cols, after) = collect_parens(after_lp)
      #(Some(string.lowercase(alias)), parse_ident_list(cols), after)
    }
    [lexer.Ident(alias), ..rest] -> #(Some(string.lowercase(alias)), [], rest)
    [lexer.QuotedIdent(alias), ..rest] -> #(
      Some(string.lowercase(alias)),
      [],
      rest,
    )
    _ -> #(None, [], after_as)
  }
}

fn parse_optional_alias(
  tokens: List(lexer.Token),
) -> #(Option(String), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("as"), lexer.Ident(name), ..rest] -> #(
      Some(string.lowercase(name)),
      rest,
    )
    [lexer.Keyword("as"), lexer.QuotedIdent(name), ..rest] -> #(
      Some(string.lowercase(name)),
      rest,
    )
    [lexer.Ident(name), ..rest] ->
      case is_reserved_after_table(name) {
        True -> #(None, tokens)
        False -> #(Some(string.lowercase(name)), rest)
      }
    [lexer.QuotedIdent(name), ..rest] -> #(Some(string.lowercase(name)), rest)
    _ -> #(None, tokens)
  }
}

fn is_reserved_after_table(name: String) -> Bool {
  let lowered = string.lowercase(name)
  list.contains(
    [
      "on", "where", "group", "having", "order", "limit", "offset", "union",
      "intersect", "except", "returning", "using", "lateral", "left", "right",
      "inner", "outer", "cross", "full", "natural", "join", "window",
    ],
    lowered,
  )
}

fn parse_join_tail(
  left: query_ir.FromItemEx,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.FromItemEx {
  case detect_join(tokens) {
    Some(#(kind, after_kw, lateral)) -> {
      let #(right_raw, after_right) = parse_primary_from(after_kw, engine)
      let #(on, after_on) = parse_join_on(after_right, engine)
      let right = parse_join_tail(right_raw, after_on, engine)
      parse_join_tail(
        query_ir.FromJoin(
          left: left,
          right: right,
          kind: kind,
          on: on,
          lateral: lateral,
        ),
        [],
        engine,
      )
    }
    None -> left
  }
}

fn detect_join(
  tokens: List(lexer.Token),
) -> Option(#(query_ir.JoinKind, List(lexer.Token), Bool)) {
  case tokens {
    [lexer.Keyword("join"), lexer.Keyword("lateral"), ..rest] ->
      Some(#(query_ir.InnerJoin, rest, True))
    [lexer.Keyword("join"), ..rest] -> Some(#(query_ir.InnerJoin, rest, False))
    [lexer.Keyword("inner"), lexer.Keyword("join"), ..rest] ->
      Some(#(query_ir.InnerJoin, rest, False))
    [lexer.Keyword("cross"), lexer.Keyword("join"), ..rest] ->
      Some(#(query_ir.CrossJoin, rest, False))
    [
      lexer.Keyword("left"),
      lexer.Keyword("join"),
      lexer.Keyword("lateral"),
      ..rest
    ] -> Some(#(query_ir.LeftJoin, rest, True))
    [
      lexer.Keyword("left"),
      lexer.Keyword("outer"),
      lexer.Keyword("join"),
      lexer.Keyword("lateral"),
      ..rest
    ] -> Some(#(query_ir.LeftJoin, rest, True))
    [
      lexer.Keyword("left"),
      lexer.Keyword("outer"),
      lexer.Keyword("join"),
      ..rest
    ] -> Some(#(query_ir.LeftJoin, rest, False))
    [lexer.Keyword("left"), lexer.Keyword("join"), ..rest] ->
      Some(#(query_ir.LeftJoin, rest, False))
    [
      lexer.Keyword("right"),
      lexer.Keyword("outer"),
      lexer.Keyword("join"),
      ..rest
    ] -> Some(#(query_ir.RightJoin, rest, False))
    [lexer.Keyword("right"), lexer.Keyword("join"), ..rest] ->
      Some(#(query_ir.RightJoin, rest, False))
    [
      lexer.Keyword("full"),
      lexer.Keyword("outer"),
      lexer.Keyword("join"),
      ..rest
    ] -> Some(#(query_ir.FullJoin, rest, False))
    [lexer.Keyword("full"), lexer.Keyword("join"), ..rest] ->
      Some(#(query_ir.FullJoin, rest, False))
    _ -> None
  }
}

fn parse_join_on(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.JoinOn, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("on"), ..rest] -> {
      let #(on_toks, after) =
        collect_until_keyword(rest, [
          "join", "inner", "left", "right", "full", "cross", "natural", "where",
          "group", "having", "order", "limit", "offset", "union", "intersect",
          "except", "returning", "window",
        ])
      #(query_ir.JoinOnExpr(expr: parse_expr(on_toks, engine)), after)
    }
    [lexer.Keyword("using"), lexer.LParen, ..rest] -> {
      let #(cols, after) = collect_parens(rest)
      #(query_ir.JoinUsing(columns: parse_ident_list(cols)), after)
    }
    _ -> #(query_ir.JoinNoCondition, tokens)
  }
}

// ============================================================
// INSERT / UPDATE / DELETE bodies
// ============================================================

fn parse_insert_body(
  ctes: List(query_ir.CteDef),
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Stmt {
  case token_utils.strip_insert_or_action(tokens) {
    [lexer.Keyword("into"), ..after_into] ->
      parse_insert_target(ctes, after_into, engine)
    _ ->
      query_ir.UnstructuredStmt(reason: "INSERT without INTO", tokens: [
        lexer.Keyword("insert"),
        ..tokens
      ])
  }
}

fn parse_insert_target(
  ctes: List(query_ir.CteDef),
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Stmt {
  let #(table_name, after_name) = read_qualified_name(tokens)
  let #(columns, after_cols) = case after_name {
    [lexer.LParen, ..after_lp] -> {
      let #(inside, after) = collect_parens(after_lp)
      #(parse_ident_list(inside), after)
    }
    _ -> #([], after_name)
  }
  let #(source, after_source) = parse_insert_source(after_cols, engine)
  // MySQL-only: consume an `ON DUPLICATE KEY UPDATE ...` tail if
  // present. For PostgreSQL and SQLite we leave the tail untouched —
  // any unexpected tokens will simply be ignored by `parse_returning`
  // (which scans for RETURNING or yields []).
  let #(on_duplicate, after_on_dup) = case engine {
    model.MySQL -> parse_on_duplicate_key_update(after_source, engine)
    _ -> #([], after_source)
  }
  let returning = parse_returning(after_on_dup, engine)
  query_ir.InsertStmt(
    ctes: ctes,
    table: table_name,
    columns: columns,
    source: source,
    on_duplicate_key_update: on_duplicate,
    returning: returning,
  )
}

fn parse_on_duplicate_key_update(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(List(query_ir.Assignment), List(lexer.Token)) {
  // `DUPLICATE` is not in the lexer's keyword list, so it arrives as an
  // `Ident`. Compare case-insensitively so users can write either case.
  case tokens {
    [
      lexer.Keyword("on"),
      lexer.Ident(duplicate),
      lexer.Keyword("key"),
      lexer.Keyword("update"),
      ..rest
    ] ->
      case string.lowercase(duplicate) {
        "duplicate" -> {
          // Collect assignments up to RETURNING or end-of-stream. Other
          // tail keywords shouldn't appear here (INSERT has no WHERE /
          // ORDER BY in MySQL's upsert form), but we stop at RETURNING
          // so the later parse_returning can still see it.
          let #(assign_toks, after) = collect_until_keyword(rest, ["returning"])
          #(parse_assignments(assign_toks, engine), after)
        }
        _ -> #([], tokens)
      }
    _ -> #([], tokens)
  }
}

fn parse_insert_source(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.InsertSource, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("default"), lexer.Keyword("values"), ..rest] -> #(
      query_ir.InsertDefaultValues,
      rest,
    )
    [lexer.Keyword("values"), ..rest] -> {
      let rows = collect_values_rows(rest, [], engine)
      // Return the tokens that sit after the last VALUES row intact.
      // For MySQL, the tail may start with ON DUPLICATE KEY UPDATE,
      // which parse_insert_target handles. For PostgreSQL / SQLite,
      // anything non-RETURNING is simply ignored downstream.
      let after = skip_values_rows(rest)
      #(query_ir.InsertValues(rows: rows), after)
    }
    [lexer.Keyword("select"), ..] -> {
      let #(core, after) = parse_select_core(tokens, engine)
      #(query_ir.InsertSelect(core: core), after)
    }
    [lexer.Keyword("with"), ..] -> {
      let stmt = parse_stmt(tokens, engine)
      case stmt {
        query_ir.SelectStmt(core: c, ..) -> #(
          query_ir.InsertSelect(core: c),
          [],
        )
        _ -> #(query_ir.InsertValues(rows: []), tokens)
      }
    }
    _ -> #(query_ir.InsertValues(rows: []), tokens)
  }
}

/// Walk past VALUES rows without consuming the tokens that follow the
/// final row. Mirrors `collect_values_rows` but returns the leftover
/// tokens instead of the parsed expression lists.
fn skip_values_rows(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.LParen, ..rest] -> {
      let #(_inner, after) = collect_parens(rest)
      case after {
        [lexer.Comma, ..more] -> skip_values_rows(more)
        _ -> after
      }
    }
    _ -> tokens
  }
}

fn parse_update_body(
  ctes: List(query_ir.CteDef),
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Stmt {
  let #(table_name, after_name) = read_qualified_name(tokens)
  let #(alias, after_alias) = parse_optional_alias(after_name)
  case after_alias {
    [lexer.Keyword("set"), ..after_set] -> {
      let #(set_toks, after_set_block) =
        collect_until_keyword(after_set, ["from", "where", "returning"])
      let assignments = parse_assignments(set_toks, engine)
      let #(from_list, after_from) = case after_set_block {
        [lexer.Keyword("from"), ..rest] -> parse_from_clause(rest, engine)
        _ -> #([], after_set_block)
      }
      let #(where_expr, after_where) = case after_from {
        [lexer.Keyword("where"), ..rest] -> {
          let #(where_toks, after) = collect_until_keyword(rest, ["returning"])
          #(Some(parse_expr(where_toks, engine)), after)
        }
        _ -> #(None, after_from)
      }
      let returning = parse_returning(after_where, engine)
      query_ir.UpdateStmt(
        ctes: ctes,
        table: table_name,
        alias: alias,
        assignments: assignments,
        from: from_list,
        where_: where_expr,
        returning: returning,
      )
    }
    _ ->
      query_ir.UnstructuredStmt(reason: "UPDATE without SET", tokens: [
        lexer.Keyword("update"),
        ..tokens
      ])
  }
}

fn parse_assignments(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> List(query_ir.Assignment) {
  tokens
  |> split_on_top_commas()
  |> list.filter_map(fn(group) { parse_assignment(group, engine) })
}

fn parse_assignment(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> Result(query_ir.Assignment, Nil) {
  case tokens {
    [lexer.Ident(col), lexer.Operator("="), ..rest] ->
      Ok(query_ir.Assignment(
        column: string.lowercase(col),
        value: parse_expr(rest, engine),
      ))
    [lexer.QuotedIdent(col), lexer.Operator("="), ..rest] ->
      Ok(query_ir.Assignment(
        column: string.lowercase(col),
        value: parse_expr(rest, engine),
      ))
    _ -> Error(Nil)
  }
}

fn parse_delete_body(
  ctes: List(query_ir.CteDef),
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Stmt {
  case tokens {
    [lexer.Keyword("from"), ..after_from] -> {
      let #(table_name, after_name) = read_qualified_name(after_from)
      let #(alias, after_alias) = parse_optional_alias(after_name)
      let #(using_list, after_using) = case after_alias {
        [lexer.Keyword("using"), ..rest] -> parse_from_clause(rest, engine)
        _ -> #([], after_alias)
      }
      let #(where_expr, after_where) = case after_using {
        [lexer.Keyword("where"), ..rest] -> {
          let #(where_toks, after) = collect_until_keyword(rest, ["returning"])
          #(Some(parse_expr(where_toks, engine)), after)
        }
        _ -> #(None, after_using)
      }
      let returning = parse_returning(after_where, engine)
      query_ir.DeleteStmt(
        ctes: ctes,
        table: table_name,
        alias: alias,
        using: using_list,
        where_: where_expr,
        returning: returning,
      )
    }
    _ ->
      query_ir.UnstructuredStmt(reason: "DELETE without FROM", tokens: [
        lexer.Keyword("delete"),
        ..tokens
      ])
  }
}

fn parse_returning(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> List(query_ir.SelectItemEx) {
  // Scan the remaining tokens for a RETURNING keyword at top level.
  // This is deliberately permissive so any leading garbage left by
  // previous parsing steps (e.g. unconsumed MySQL-only tails on a
  // PostgreSQL engine) is tolerated without losing the RETURNING
  // projection when it does appear.
  case skip_to_returning_or_end(tokens) {
    [lexer.Keyword("returning"), ..rest] -> {
      let filtered =
        list.filter(rest, fn(t) {
          case t {
            lexer.Semicolon -> False
            _ -> True
          }
        })
      parse_select_items(filtered, engine)
    }
    _ -> []
  }
}

// ============================================================
// Expressions
// ============================================================

pub fn parse_expr(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.Expr {
  let #(expr, rest) = parse_or(trim_noise(tokens), engine)
  case rest {
    [] -> expr
    _ ->
      query_ir.RawExpr(
        reason: "trailing tokens after expression",
        tokens: tokens,
      )
  }
}

fn parse_expr_list(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> List(query_ir.Expr) {
  tokens
  |> split_on_top_commas()
  |> list.map(fn(group) { parse_expr(group, engine) })
}

fn parse_or(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(left, rest) = parse_and(tokens, engine)
  parse_or_tail(left, rest, engine)
}

fn parse_or_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("or"), ..rest] -> {
      let #(right, after) = parse_and(rest, engine)
      parse_or_tail(
        query_ir.Binary(op: "or", left: left, right: right),
        after,
        engine,
      )
    }
    _ -> #(left, tokens)
  }
}

fn parse_and(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(left, rest) = parse_not(tokens, engine)
  parse_and_tail(left, rest, engine)
}

fn parse_and_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("and"), ..rest] -> {
      let #(right, after) = parse_not(rest, engine)
      parse_and_tail(
        query_ir.Binary(op: "and", left: left, right: right),
        after,
        engine,
      )
    }
    _ -> #(left, tokens)
  }
}

fn parse_not(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("not"), ..rest] -> {
      let #(inner, after) = parse_not(rest, engine)
      #(query_ir.Unary(op: "not", arg: inner), after)
    }
    _ -> parse_comparison(tokens, engine)
  }
}

fn parse_comparison(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(left, rest) = parse_additive(tokens, engine)
  parse_comparison_tail(left, rest, engine)
}

fn parse_comparison_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Operator(op), ..rest]
      if op == "="
      || op == "<>"
      || op == "!="
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
      || op == "@>"
      || op == "<@"
      || op == "?|"
      || op == "?&"
      || op == "&&"
    -> {
      case rest {
        [lexer.Keyword("any"), lexer.LParen, ..after_lp] -> {
          let #(inner, after) = collect_parens(after_lp)
          let right = parse_expr(inner, engine)
          #(
            query_ir.Quantified(
              op: op,
              left: left,
              quantifier: query_ir.QAny,
              right: right,
            ),
            after,
          )
        }
        [lexer.Keyword("all"), lexer.LParen, ..after_lp] -> {
          let #(inner, after) = collect_parens(after_lp)
          let right = parse_expr(inner, engine)
          #(
            query_ir.Quantified(
              op: op,
              left: left,
              quantifier: query_ir.QAll,
              right: right,
            ),
            after,
          )
        }
        _ -> {
          let #(right, after) = parse_additive(rest, engine)
          #(query_ir.Binary(op: op, left: left, right: right), after)
        }
      }
    }
    [lexer.Keyword("is"), lexer.Keyword("not"), lexer.Keyword("null"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsNull, negated: True),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("null"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsNull, negated: False),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("not"), lexer.Keyword("true"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsTrue, negated: True),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("true"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsTrue, negated: False),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("not"), lexer.Keyword("false"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsFalse, negated: True),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("false"), ..rest] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsFalse, negated: False),
      rest,
    )
    [
      lexer.Keyword("is"),
      lexer.Keyword("not"),
      lexer.Keyword("unknown"),
      ..rest
    ] -> #(
      query_ir.IsCheck(expr: left, predicate: query_ir.IsUnknown, negated: True),
      rest,
    )
    [lexer.Keyword("is"), lexer.Keyword("unknown"), ..rest] -> #(
      query_ir.IsCheck(
        expr: left,
        predicate: query_ir.IsUnknown,
        negated: False,
      ),
      rest,
    )
    [lexer.Keyword("not"), lexer.Keyword("in"), ..rest] ->
      parse_in_tail(left, rest, True, engine)
    [lexer.Keyword("in"), ..rest] -> parse_in_tail(left, rest, False, engine)
    [lexer.Keyword("not"), lexer.Keyword("between"), ..rest] ->
      parse_between_tail(left, rest, True, engine)
    [lexer.Keyword("between"), ..rest] ->
      parse_between_tail(left, rest, False, engine)
    [lexer.Keyword("not"), lexer.Keyword("like"), ..rest] ->
      parse_like_tail(left, rest, query_ir.Like, True, engine)
    [lexer.Keyword("like"), ..rest] ->
      parse_like_tail(left, rest, query_ir.Like, False, engine)
    [lexer.Keyword("not"), lexer.Keyword("ilike"), ..rest] ->
      parse_like_tail(left, rest, query_ir.Ilike, True, engine)
    [lexer.Keyword("ilike"), ..rest] ->
      parse_like_tail(left, rest, query_ir.Ilike, False, engine)
    _ -> #(left, tokens)
  }
}

fn parse_in_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  negated: Bool,
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.LParen, lexer.Keyword("select"), ..] -> {
      let #(inner, after) = collect_parens(drop_first(tokens))
      let #(core, _) = parse_select_core(inner, engine)
      #(
        query_ir.InExpr(
          expr: left,
          source: query_ir.InSubquery(core: core),
          negated: negated,
        ),
        after,
      )
    }
    [lexer.LParen, ..rest] -> {
      let #(inner, after) = collect_parens(rest)
      case detect_slice_macro(inner) {
        Some(name) -> #(
          query_ir.InExpr(
            expr: left,
            source: query_ir.InSliceMacro(name: name),
            negated: negated,
          ),
          after,
        )
        None -> {
          let values = parse_expr_list(inner, engine)
          #(
            query_ir.InExpr(
              expr: left,
              source: query_ir.InList(values: values),
              negated: negated,
            ),
            after,
          )
        }
      }
    }
    _ -> #(
      query_ir.RawExpr(reason: "IN without paren list", tokens: tokens),
      [],
    )
  }
}

fn detect_slice_macro(tokens: List(lexer.Token)) -> Option(String) {
  case tokens {
    [
      lexer.Ident(s),
      lexer.Dot,
      lexer.Ident(sl),
      lexer.LParen,
      lexer.Ident(name),
      lexer.RParen,
    ] ->
      case string.lowercase(s), string.lowercase(sl) {
        "sqlode", "slice" -> Some(string.lowercase(name))
        _, _ -> None
      }
    _ -> None
  }
}

fn parse_between_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  negated: Bool,
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(low, rest) = parse_additive(tokens, engine)
  case rest {
    [lexer.Keyword("and"), ..after_and] -> {
      let #(high, after) = parse_additive(after_and, engine)
      #(
        query_ir.Between(expr: left, low: low, high: high, negated: negated),
        after,
      )
    }
    _ -> #(query_ir.RawExpr(reason: "BETWEEN without AND", tokens: tokens), [])
  }
}

fn parse_like_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  op: query_ir.LikeOp,
  negated: Bool,
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(pattern, rest) = parse_additive(tokens, engine)
  let #(escape, rest2) = case rest {
    [lexer.Keyword("escape"), ..more] -> {
      let #(esc, after) = parse_additive(more, engine)
      #(Some(esc), after)
    }
    _ -> #(None, rest)
  }
  #(
    query_ir.LikeExpr(
      expr: left,
      op: op,
      pattern: pattern,
      escape: escape,
      negated: negated,
    ),
    rest2,
  )
}

fn parse_additive(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(left, rest) = parse_multiplicative(tokens, engine)
  parse_additive_tail(left, rest, engine)
}

fn parse_additive_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Operator(op), ..rest]
      if op == "+"
      || op == "-"
      || op == "||"
      || op == "->"
      || op == "->>"
      || op == "#>"
      || op == "#>>"
    -> {
      let #(right, after) = parse_multiplicative(rest, engine)
      parse_additive_tail(
        query_ir.Binary(op: op, left: left, right: right),
        after,
        engine,
      )
    }
    _ -> #(left, tokens)
  }
}

fn parse_multiplicative(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(left, rest) = parse_unary(tokens, engine)
  parse_multiplicative_tail(left, rest, engine)
}

fn parse_multiplicative_tail(
  left: query_ir.Expr,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Star, ..rest] -> {
      let #(right, after) = parse_unary(rest, engine)
      parse_multiplicative_tail(
        query_ir.Binary(op: "*", left: left, right: right),
        after,
        engine,
      )
    }
    [lexer.Operator(op), ..rest] if op == "/" || op == "%" -> {
      let #(right, after) = parse_unary(rest, engine)
      parse_multiplicative_tail(
        query_ir.Binary(op: op, left: left, right: right),
        after,
        engine,
      )
    }
    _ -> #(left, tokens)
  }
}

fn parse_unary(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Operator("-"), ..rest] -> {
      let #(inner, after) = parse_unary(rest, engine)
      #(query_ir.Unary(op: "-", arg: inner), after)
    }
    [lexer.Operator("+"), ..rest] -> {
      let #(inner, after) = parse_unary(rest, engine)
      #(query_ir.Unary(op: "+", arg: inner), after)
    }
    _ -> parse_cast(tokens, engine)
  }
}

fn parse_cast(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(atom, rest) = parse_atom(tokens, engine)
  parse_cast_tail(atom, rest)
}

// `parse_cast_tail` does not take `engine` because the `::type` suffix
// parses only a type name via `read_type_tokens`, which is a pure
// token-shape helper and not dialect-sensitive.
fn parse_cast_tail(
  atom: query_ir.Expr,
  tokens: List(lexer.Token),
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Operator("::"), ..rest] -> {
      let #(type_name, after) = read_type_tokens(rest)
      parse_cast_tail(query_ir.Cast(expr: atom, target_type: type_name), after)
    }
    _ -> #(atom, tokens)
  }
}

fn read_type_tokens(tokens: List(lexer.Token)) -> #(String, List(lexer.Token)) {
  collect_type_tokens(tokens, [])
}

fn collect_type_tokens(
  tokens: List(lexer.Token),
  acc: List(String),
) -> #(String, List(lexer.Token)) {
  case tokens {
    [lexer.Ident(n), ..rest] ->
      collect_type_tokens(rest, [string.lowercase(n), ..acc])
    [lexer.Keyword(k), ..rest] -> collect_type_tokens(rest, [k, ..acc])
    [lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      let inside_text = render_type_parens(inside)
      let last_acc = case acc {
        [first, ..rest_acc] -> [first <> "(" <> inside_text <> ")", ..rest_acc]
        [] -> ["(" <> inside_text <> ")"]
      }
      collect_type_tokens(after, last_acc)
    }
    [lexer.Operator("[]"), ..rest] ->
      case acc {
        [first, ..rest_acc] ->
          collect_type_tokens(rest, [first <> "[]", ..rest_acc])
        [] -> collect_type_tokens(rest, ["[]"])
      }
    _ -> #(list.reverse(acc) |> string.join(" ") |> string.trim, tokens)
  }
}

fn render_type_parens(tokens: List(lexer.Token)) -> String {
  tokens
  |> list.map(fn(t) {
    case t {
      lexer.Ident(n) -> n
      lexer.Keyword(k) -> k
      lexer.NumberLit(n) -> n
      lexer.Comma -> ","
      _ -> ""
    }
  })
  |> string.join("")
}

fn parse_atom(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [] -> #(query_ir.RawExpr(reason: "empty expression", tokens: []), [])
    [lexer.Keyword("null"), ..rest] -> #(query_ir.NullLit, rest)
    [lexer.Keyword("true"), ..rest] -> #(query_ir.BoolLit(value: True), rest)
    [lexer.Keyword("false"), ..rest] -> #(query_ir.BoolLit(value: False), rest)
    [lexer.StringLit(v), ..rest] -> #(query_ir.StringLit(value: v), rest)
    [lexer.NumberLit(n), ..rest] -> #(query_ir.NumberLit(value: n), rest)
    [lexer.Placeholder(raw), ..rest] -> {
      let idx = decode_placeholder(raw)
      #(query_ir.Param(index: idx, raw: raw), rest)
    }
    [lexer.Keyword("case"), ..rest] -> parse_case(rest, engine)
    [lexer.Keyword("cast"), lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      let #(expr_tokens, as_rest) = split_on_as(inside)
      let target =
        as_rest
        |> list.map(fn(t) {
          case t {
            lexer.Ident(n) -> n
            lexer.Keyword(k) -> k
            _ -> ""
          }
        })
        |> list.filter(fn(s) { s != "" })
        |> string.join(" ")
      #(
        query_ir.Cast(
          expr: parse_expr(expr_tokens, engine),
          target_type: target,
        ),
        after,
      )
    }
    [lexer.Keyword("not"), lexer.Keyword("exists"), lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      let #(core, _) = parse_select_core(inside, engine)
      #(query_ir.Exists(core: core, negated: True), after)
    }
    [lexer.Keyword("exists"), lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      let #(core, _) = parse_select_core(inside, engine)
      #(query_ir.Exists(core: core, negated: False), after)
    }
    [lexer.Keyword("array"), lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      let #(core, _) = parse_select_core(inside, engine)
      #(query_ir.ScalarSubquery(core: core), after)
    }
    [lexer.Keyword("array"), lexer.Operator("["), ..rest] -> {
      let #(inside, after) = collect_brackets(rest)
      #(query_ir.ArrayLit(elements: parse_expr_list(inside, engine)), after)
    }
    [lexer.LParen, lexer.Keyword("select"), ..] -> {
      let #(inside, after) = collect_parens(drop_first(tokens))
      let #(core, _) = parse_select_core(inside, engine)
      #(query_ir.ScalarSubquery(core: core), after)
    }
    [lexer.LParen, lexer.Keyword("with"), ..] -> {
      let #(inside, after) = collect_parens(drop_first(tokens))
      let stmt = parse_stmt(inside, engine)
      case stmt {
        query_ir.SelectStmt(core: c, ..) -> #(
          query_ir.ScalarSubquery(core: c),
          after,
        )
        _ -> #(
          query_ir.RawExpr(
            reason: "non-SELECT subquery in expression",
            tokens: tokens,
          ),
          [],
        )
      }
    }
    [lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      case split_on_top_commas(inside) {
        [single] -> #(parse_expr(single, engine), after)
        many -> #(
          query_ir.Tuple(
            elements: list.map(many, fn(group) { parse_expr(group, engine) }),
          ),
          after,
        )
      }
    }
    [lexer.Keyword("interval"), lexer.StringLit(val), ..rest] -> #(
      query_ir.Func(
        name: "interval",
        args: [query_ir.FuncArg(expr: query_ir.StringLit(value: val))],
        distinct: False,
        filter: None,
        over: None,
      ),
      rest,
    )
    [lexer.Ident(s), lexer.Dot, lexer.Ident(name), lexer.LParen, ..rest] ->
      case string.lowercase(s) {
        "sqlode" -> {
          let #(inside, after) = collect_parens(rest)
          #(query_ir.Macro(name: string.lowercase(name), body: inside), after)
        }
        _ -> parse_function_call(name, [lexer.LParen, ..rest], engine)
      }
    [lexer.Ident(name), lexer.LParen, ..rest] ->
      parse_function_call(name, rest, engine)
    [lexer.Ident(table), lexer.Dot, lexer.Star, ..rest] -> #(
      query_ir.StarRef(table: Some(string.lowercase(table))),
      rest,
    )
    [lexer.Ident(table), lexer.Dot, lexer.Operator("*"), ..rest] -> #(
      query_ir.StarRef(table: Some(string.lowercase(table))),
      rest,
    )
    [lexer.Ident(table), lexer.Dot, lexer.Ident(col), ..rest] -> #(
      query_ir.ColumnRef(
        table: Some(string.lowercase(table)),
        name: string.lowercase(col),
      ),
      rest,
    )
    [lexer.Ident(table), lexer.Dot, lexer.QuotedIdent(col), ..rest] -> #(
      query_ir.ColumnRef(
        table: Some(string.lowercase(table)),
        name: string.lowercase(col),
      ),
      rest,
    )
    [lexer.Ident(name), ..rest] -> #(
      query_ir.ColumnRef(table: None, name: string.lowercase(name)),
      rest,
    )
    [lexer.QuotedIdent(name), ..rest] -> #(
      query_ir.ColumnRef(table: None, name: string.lowercase(name)),
      rest,
    )
    [lexer.Star, ..rest] -> #(query_ir.StarRef(table: None), rest)
    [lexer.Operator("*"), ..rest] -> #(query_ir.StarRef(table: None), rest)
    _ -> #(query_ir.RawExpr(reason: "unrecognised atom", tokens: tokens), [])
  }
}

fn parse_function_call(
  name: String,
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(inside, after) = collect_parens(tokens)
  let #(distinct, args_tokens) = case inside {
    [lexer.Keyword("distinct"), ..rest] -> #(True, rest)
    _ -> #(False, inside)
  }
  let args = case args_tokens {
    [] -> []
    _ ->
      args_tokens
      |> split_on_top_commas()
      |> list.map(fn(group) {
        query_ir.FuncArg(expr: parse_expr(group, engine))
      })
  }
  let #(filter, after_filter) = parse_filter_clause(after, engine)
  let #(over, after_over) = parse_over_clause(after_filter, engine)
  #(
    query_ir.Func(
      name: string.lowercase(name),
      args: args,
      distinct: distinct,
      filter: filter,
      over: over,
    ),
    after_over,
  )
}

fn parse_filter_clause(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(Option(query_ir.Expr), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("filter"), lexer.LParen, lexer.Keyword("where"), ..rest] -> {
      let #(inside, after) = collect_parens_after_where(rest)
      #(Some(parse_expr(inside, engine)), after)
    }
    _ -> #(None, tokens)
  }
}

fn collect_parens_after_where(
  tokens: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  // `rest` is already past `LParen` `where`, so depth is 1 and current
  // contents are the WHERE predicate tokens until the matching RParen.
  collect_parens(tokens)
}

fn parse_over_clause(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(Option(query_ir.WindowSpec), List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("over"), lexer.LParen, ..rest] -> {
      let #(inside, after) = collect_parens(rest)
      #(Some(parse_window_spec(inside, engine)), after)
    }
    [lexer.Keyword("over"), lexer.Ident(_), ..rest] -> {
      // Named window reference — treat as empty spec; the named
      // window definition is not followed into right now.
      #(
        Some(query_ir.WindowSpec(partition_by: [], order_by: [], frame: None)),
        rest,
      )
    }
    _ -> #(None, tokens)
  }
}

fn parse_window_spec(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> query_ir.WindowSpec {
  let #(_name_skipped, rest) = case tokens {
    [lexer.Ident(_), ..rest] -> #(True, rest)
    _ -> #(False, tokens)
  }
  let #(partition_by, rest2) = case rest {
    [lexer.Keyword("partition"), lexer.Keyword("by"), ..more] -> {
      let #(p_toks, after) =
        collect_until_keyword(more, ["order", "range", "rows", "groups"])
      #(parse_expr_list(p_toks, engine), after)
    }
    _ -> #([], rest)
  }
  let #(order_by, rest3) = case rest2 {
    [lexer.Keyword("order"), lexer.Keyword("by"), ..more] -> {
      let #(o_toks, after) =
        collect_until_keyword(more, ["range", "rows", "groups"])
      #(parse_order_keys(o_toks, engine), after)
    }
    _ -> #([], rest2)
  }
  let frame = case rest3 {
    [] -> None
    other -> Some(other)
  }
  query_ir.WindowSpec(
    partition_by: partition_by,
    order_by: order_by,
    frame: frame,
  )
}

fn parse_case(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  let #(scrutinee, rest) = case tokens {
    [lexer.Keyword("when"), ..] -> #(None, tokens)
    _ -> {
      let #(scr_toks, after) =
        collect_until_keyword(tokens, ["when", "else", "end"])
      case scr_toks {
        [] -> #(None, after)
        _ -> #(Some(parse_expr(scr_toks, engine)), after)
      }
    }
  }
  collect_case_branches(rest, scrutinee, [], engine)
}

fn collect_case_branches(
  tokens: List(lexer.Token),
  scrutinee: Option(query_ir.Expr),
  branches: List(query_ir.CaseBranch),
  engine: model.Engine,
) -> #(query_ir.Expr, List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("when"), ..rest] -> {
      let #(when_toks, after_when) = collect_until_keyword(rest, ["then"])
      let after_then = case after_when {
        [lexer.Keyword("then"), ..more] -> more
        _ -> after_when
      }
      let #(then_toks, after_then_block) =
        collect_until_keyword(after_then, ["when", "else", "end"])
      let branch =
        query_ir.CaseBranch(
          when_: parse_expr(when_toks, engine),
          then: parse_expr(then_toks, engine),
        )
      collect_case_branches(
        after_then_block,
        scrutinee,
        [branch, ..branches],
        engine,
      )
    }
    [lexer.Keyword("else"), ..rest] -> {
      let #(else_toks, after_else) = collect_until_keyword(rest, ["end"])
      let after_end = case after_else {
        [lexer.Keyword("end"), ..more] -> more
        _ -> after_else
      }
      #(
        query_ir.Case(
          scrutinee: scrutinee,
          branches: list.reverse(branches),
          else_: Some(parse_expr(else_toks, engine)),
        ),
        after_end,
      )
    }
    [lexer.Keyword("end"), ..rest] -> #(
      query_ir.Case(
        scrutinee: scrutinee,
        branches: list.reverse(branches),
        else_: None,
      ),
      rest,
    )
    _ -> #(
      query_ir.Case(
        scrutinee: scrutinee,
        branches: list.reverse(branches),
        else_: None,
      ),
      tokens,
    )
  }
}

// ============================================================
// Token helpers
// ============================================================

fn split_on_top_commas(tokens: List(lexer.Token)) -> List(List(lexer.Token)) {
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
    [t, ..rest] -> split_commas_loop(rest, depth, [t, ..current], acc)
  }
}

fn collect_parens(
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
        [t, ..rest] -> collect_paren_loop(rest, depth, [t, ..acc])
      }
  }
}

fn collect_brackets(
  tokens: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  collect_bracket_loop(tokens, 1, [])
}

fn collect_bracket_loop(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case depth <= 0 {
    True -> #(list.reverse(acc), tokens)
    False ->
      case tokens {
        [] -> #(list.reverse(acc), [])
        [lexer.Operator("["), ..rest] ->
          collect_bracket_loop(rest, depth + 1, [lexer.Operator("["), ..acc])
        [lexer.Operator("]"), ..rest] ->
          case depth == 1 {
            True -> #(list.reverse(acc), rest)
            False ->
              collect_bracket_loop(rest, depth - 1, [lexer.Operator("]"), ..acc])
          }
        [t, ..rest] -> collect_bracket_loop(rest, depth, [t, ..acc])
      }
  }
}

fn collect_until_keyword(
  tokens: List(lexer.Token),
  stop: List(String),
) -> #(List(lexer.Token), List(lexer.Token)) {
  collect_until_loop(tokens, stop, 0, [])
}

fn collect_until_loop(
  tokens: List(lexer.Token),
  stop: List(String),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case tokens {
    [] -> #(list.reverse(acc), [])
    [lexer.LParen, ..rest] ->
      collect_until_loop(rest, stop, depth + 1, [lexer.LParen, ..acc])
    [lexer.RParen, ..rest] ->
      collect_until_loop(rest, stop, depth - 1, [lexer.RParen, ..acc])
    [lexer.Keyword(kw), ..rest] as t if depth == 0 -> {
      case list.contains(stop, kw) {
        True -> #(list.reverse(acc), t)
        False ->
          collect_until_loop(rest, stop, depth, [lexer.Keyword(kw), ..acc])
      }
    }
    [t, ..rest] -> collect_until_loop(rest, stop, depth, [t, ..acc])
  }
}

fn read_qualified_name(
  tokens: List(lexer.Token),
) -> #(String, List(lexer.Token)) {
  case tokens {
    [lexer.Ident(_), lexer.Dot, lexer.Ident(name), ..rest] -> #(
      string.lowercase(name),
      rest,
    )
    [lexer.Ident(name), ..rest] -> #(string.lowercase(name), rest)
    [lexer.QuotedIdent(name), ..rest] -> #(string.lowercase(name), rest)
    _ -> #("", tokens)
  }
}

fn drop_first(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [_, ..rest] -> rest
    [] -> []
  }
}

fn empty_core() -> query_ir.SelectCore {
  query_ir.SelectCore(
    distinct: False,
    select_items: [],
    from: [],
    where_: None,
    group_by: [],
    having: None,
    order_by: [],
    limit: None,
    offset: None,
    set_op: None,
  )
}

fn trim_noise(tokens: List(lexer.Token)) -> List(lexer.Token) {
  list.filter(tokens, fn(t) {
    case t {
      lexer.Semicolon -> False
      _ -> True
    }
  })
}

fn split_on_as(
  tokens: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  split_on_as_loop(tokens, 0, [])
}

fn split_on_as_loop(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case tokens {
    [] -> #(list.reverse(acc), [])
    [lexer.LParen, ..rest] ->
      split_on_as_loop(rest, depth + 1, [lexer.LParen, ..acc])
    [lexer.RParen, ..rest] ->
      split_on_as_loop(rest, depth - 1, [lexer.RParen, ..acc])
    [lexer.Keyword("as"), ..rest] if depth == 0 -> #(list.reverse(acc), rest)
    [t, ..rest] -> split_on_as_loop(rest, depth, [t, ..acc])
  }
}

fn skip_to_returning_or_end(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [] -> []
    [lexer.Keyword("returning"), ..] as t -> t
    [_, ..rest] -> skip_to_returning_or_end(rest)
  }
}

fn decode_placeholder(raw: String) -> Int {
  // Accept $N, ?N, :N, @N; when missing, default to 0 so the analyzer
  // can surface ParameterTypeNotInferred on it.
  let digits = case string.to_graphemes(raw) {
    [] -> ""
    [_first, ..rest] -> string.concat(rest)
  }
  case int.parse(digits) {
    Ok(n) -> n
    Error(_) -> 0
  }
}
