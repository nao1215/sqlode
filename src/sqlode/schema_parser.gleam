import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/token_utils

pub type ParseError {
  InvalidCreateTable(detail: String)
  InvalidColumn(table: String, detail: String)
}

type ParsedSchema {
  ParsedSchema(tables: List(model.Table), enums: List(model.EnumDef))
}

type ViewColumn {
  ViewColumn(name: String, expr_tokens: List(lexer.Token))
}

pub fn parse_files(
  entries: List(#(String, String)),
) -> Result(model.Catalog, ParseError) {
  parse_files_with_engine(entries, model.PostgreSQL)
}

pub fn parse_files_with_engine(
  entries: List(#(String, String)),
  engine: model.Engine,
) -> Result(model.Catalog, ParseError) {
  entries
  |> list.try_fold(ParsedSchema(tables: [], enums: []), fn(acc, entry) {
    let #(_path, content) = entry
    use parsed <- result.try(parse_content(content, acc.enums, engine))
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
  engine: model.Engine,
) -> Result(ParsedSchema, ParseError) {
  let tokens = lexer.tokenize(content, engine)
  let statements = split_token_statements(tokens, [], [])

  let enums =
    statements
    |> list.filter_map(fn(stmt_tokens) {
      case is_create_enum_tokens(stmt_tokens) {
        True -> parse_create_enum_from_tokens(stmt_tokens)
        False -> Error(Nil)
      }
    })

  let all_enums = list.append(known_enums, enums)

  use tables <- result.try(
    statements
    |> list.try_fold([], fn(tables, stmt_tokens) {
      case is_create_view_tokens(stmt_tokens) {
        True -> {
          let maybe_table =
            parse_create_view_from_tokens(stmt_tokens, list.reverse(tables))
          Ok(case maybe_table {
            Some(table) -> [table, ..tables]
            None -> tables
          })
        }
        False ->
          case is_alter_table_add_column_tokens(stmt_tokens) {
            True -> apply_alter_table_add_column(stmt_tokens, all_enums, tables)
            False -> {
              use maybe_table <- result.try(parse_statement_tokens(
                stmt_tokens,
                all_enums,
              ))
              Ok(case maybe_table {
                Some(table) -> [table, ..tables]
                None -> tables
              })
            }
          }
      }
    })
    |> result.map(list.reverse),
  )

  Ok(ParsedSchema(tables:, enums:))
}

// --- Lexer-based helpers ---

/// Split token list on Semicolon tokens into a list of statements.
fn split_token_statements(
  tokens: List(lexer.Token),
  current: List(lexer.Token),
  acc: List(List(lexer.Token)),
) -> List(List(lexer.Token)) {
  case tokens {
    [] ->
      case current {
        [] -> list.reverse(acc)
        _ -> list.reverse([list.reverse(current), ..acc])
      }
    [lexer.Semicolon, ..rest] ->
      case current {
        [] -> split_token_statements(rest, [], acc)
        _ -> split_token_statements(rest, [], [list.reverse(current), ..acc])
      }
    [token, ..rest] -> split_token_statements(rest, [token, ..current], acc)
  }
}

/// Check if a token list represents a CREATE TYPE ... AS ENUM statement.
fn is_create_enum_tokens(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [
      lexer.Keyword("create"),
      lexer.Keyword("type"),
      _,
      lexer.Keyword("as"),
      lexer.Keyword("enum"),
      ..
    ] -> True
    _ -> False
  }
}

/// Parse a CREATE TYPE name AS ENUM (...) from tokens, handling escaped quotes correctly.
fn parse_create_enum_from_tokens(
  tokens: List(lexer.Token),
) -> Result(model.EnumDef, Nil) {
  case tokens {
    [
      lexer.Keyword("create"),
      lexer.Keyword("type"),
      name_token,
      lexer.Keyword("as"),
      lexer.Keyword("enum"),
      ..rest
    ] -> {
      let name = case name_token {
        lexer.Ident(n) -> string.lowercase(n)
        lexer.QuotedIdent(n) -> string.lowercase(n)
        _ -> ""
      }
      let values = extract_enum_values(rest, [])
      Ok(model.EnumDef(name:, values:))
    }
    _ -> Error(Nil)
  }
}

/// Extract string literal values from inside ENUM parentheses.
fn extract_enum_values(
  tokens: List(lexer.Token),
  acc: List(String),
) -> List(String) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.StringLit(value), ..rest] ->
      extract_enum_values(rest, [value, ..acc])
    [_, ..rest] -> extract_enum_values(rest, acc)
  }
}

fn is_create_view_tokens(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [
      lexer.Keyword("create"),
      lexer.Keyword("or"),
      lexer.Keyword("replace"),
      lexer.Keyword("view"),
      ..
    ] -> True
    [lexer.Keyword("create"), lexer.Keyword("view"), ..] -> True
    _ -> False
  }
}

fn parse_create_view_from_tokens(
  tokens: List(lexer.Token),
  tables: List(model.Table),
) -> Option(model.Table) {
  let remaining = case tokens {
    [
      lexer.Keyword("create"),
      lexer.Keyword("or"),
      lexer.Keyword("replace"),
      lexer.Keyword("view"),
      ..rest
    ] -> rest
    [lexer.Keyword("create"), lexer.Keyword("view"), ..rest] -> rest
    _ -> []
  }

  // Extract view name
  let #(view_name, after_name) = case remaining {
    [lexer.Ident(n), ..rest] -> #(string.lowercase(n), rest)
    [lexer.QuotedIdent(n), ..rest] -> #(string.lowercase(n), rest)
    _ -> #("", [])
  }

  case view_name {
    "" -> None
    _ -> {
      // Skip to AS keyword
      let after_as = skip_to_keyword(after_name, "as")
      // Skip past SELECT keyword
      let after_select = case after_as {
        [lexer.Keyword("select"), ..rest] -> rest
        _ -> []
      }

      case after_select {
        [] -> None
        _ -> {
          // Find FROM keyword at depth 0 to split SELECT columns from FROM clause
          let #(select_tokens, from_tokens) = split_at_from(after_select, 0, [])

          // Extract table names from FROM clause (prepend "from" keyword
          // because split_at_from already consumed it)
          let source_tables =
            token_utils.extract_table_names([
              lexer.Keyword("from"),
              ..from_tokens
            ])

          case select_tokens {
            [lexer.Star] -> {
              let columns =
                list.flat_map(source_tables, fn(table_name) {
                  case list.find(tables, fn(t) { t.name == table_name }) {
                    Ok(table) -> table.columns
                    Error(_) -> []
                  }
                })
              case columns {
                [] -> None
                _ -> Some(model.Table(name: view_name, columns: columns))
              }
            }
            _ -> {
              let view_cols = extract_view_columns(select_tokens)
              let columns =
                list.filter_map(view_cols, fn(view_col) {
                  let normalized = naming.normalize_identifier(view_col.name)
                  case find_column_in_tables(tables, normalized) {
                    Some(col) -> Ok(model.Column(..col, name: normalized))
                    None ->
                      case
                        resolve_column_from_expr_tokens(
                          view_col.expr_tokens,
                          tables,
                        )
                      {
                        Some(col) -> Ok(model.Column(..col, name: normalized))
                        None ->
                          case
                            infer_view_expression_type(
                              view_col.expr_tokens,
                              tables,
                            )
                          {
                            Some(#(scalar_type, nullable)) ->
                              Ok(model.Column(
                                name: normalized,
                                scalar_type: scalar_type,
                                nullable: nullable,
                              ))
                            None -> {
                              io.println_error(
                                "Warning: view column \""
                                <> normalized
                                <> "\" could not be resolved from source tables"
                                <> " — skipping column.",
                              )
                              Error(Nil)
                            }
                          }
                      }
                  }
                })
              case columns {
                [] -> None
                _ -> Some(model.Table(name: view_name, columns:))
              }
            }
          }
        }
      }
    }
  }
}

fn skip_to_keyword(
  tokens: List(lexer.Token),
  keyword: String,
) -> List(lexer.Token) {
  case tokens {
    [] -> []
    [lexer.Keyword(k), ..rest] if k == keyword -> rest
    [_, ..rest] -> skip_to_keyword(rest, keyword)
  }
}

fn split_at_from(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case tokens {
    [] -> #(list.reverse(acc), [])
    [lexer.LParen, ..rest] ->
      split_at_from(rest, depth + 1, [lexer.LParen, ..acc])
    [lexer.RParen, ..rest] ->
      split_at_from(rest, depth - 1, [lexer.RParen, ..acc])
    [lexer.Keyword("from"), ..rest] if depth == 0 -> #(list.reverse(acc), rest)
    [token, ..rest] -> split_at_from(rest, depth, [token, ..acc])
  }
}

fn extract_view_columns(tokens: List(lexer.Token)) -> List(ViewColumn) {
  let groups = tok_split_select_columns(tokens, 0, [], [])
  list.filter_map(groups, fn(col_tokens) {
    // Check for AS alias (last two tokens: Keyword("as"), Ident/QuotedIdent)
    let reversed = list.reverse(col_tokens)
    case reversed {
      [lexer.Ident(alias), lexer.Keyword("as"), ..rest] ->
        Ok(ViewColumn(name: alias, expr_tokens: list.reverse(rest)))
      [lexer.QuotedIdent(alias), lexer.Keyword("as"), ..rest] ->
        Ok(ViewColumn(name: alias, expr_tokens: list.reverse(rest)))
      _ -> {
        // Check for table.column → use column
        case list.reverse(reversed) {
          [lexer.Ident(_table), lexer.Dot, lexer.Ident(col)] ->
            Ok(ViewColumn(name: col, expr_tokens: col_tokens))
          _ ->
            // Use the last identifier
            case reversed {
              [lexer.Ident(name), ..] ->
                Ok(ViewColumn(name: name, expr_tokens: col_tokens))
              [lexer.QuotedIdent(name), ..] ->
                Ok(ViewColumn(name: name, expr_tokens: col_tokens))
              _ -> Error(Nil)
            }
        }
      }
    }
  })
}

fn resolve_column_from_expr_tokens(
  expr_tokens: List(lexer.Token),
  tables: List(model.Table),
) -> Option(model.Column) {
  case expr_tokens {
    [lexer.Ident(name)] -> find_column_in_tables(tables, string.lowercase(name))
    [lexer.QuotedIdent(name)] ->
      find_column_in_tables(tables, string.lowercase(name))
    [lexer.Ident(_table), lexer.Dot, lexer.Ident(col)] ->
      find_column_in_tables(tables, string.lowercase(col))
    [lexer.QuotedIdent(_table), lexer.Dot, lexer.Ident(col)] ->
      find_column_in_tables(tables, string.lowercase(col))
    _ -> None
  }
}

fn infer_view_expression_type(
  expr_tokens: List(lexer.Token),
  tables: List(model.Table),
) -> Option(#(model.ScalarType, Bool)) {
  case expr_tokens {
    [lexer.Keyword("count"), lexer.LParen, ..] -> Some(#(model.IntType, False))
    [lexer.Keyword("avg"), lexer.LParen, ..rest] ->
      Some(#(
        case extract_aggregate_inner_type(rest, tables) {
          Some(col) ->
            case col.scalar_type {
              model.IntType | model.FloatType -> model.FloatType
              other -> other
            }
          None -> model.FloatType
        },
        True,
      ))
    [lexer.Keyword("sum"), lexer.LParen, ..rest] ->
      case extract_aggregate_inner_type(rest, tables) {
        Some(col) -> Some(#(col.scalar_type, True))
        None -> Some(#(model.FloatType, True))
      }
    [lexer.Keyword(fn_name), lexer.LParen, ..rest]
      if fn_name == "min" || fn_name == "max"
    ->
      case extract_aggregate_inner_type(rest, tables) {
        Some(col) -> Some(#(col.scalar_type, True))
        None -> None
      }
    [lexer.Keyword("coalesce"), lexer.LParen, ..rest] ->
      case extract_aggregate_inner_type(rest, tables) {
        Some(col) -> Some(#(col.scalar_type, False))
        None -> None
      }
    [lexer.Keyword("cast"), lexer.LParen, ..rest] -> infer_cast_type(rest)
    [lexer.Keyword(fn_name), lexer.LParen, ..]
      if fn_name == "row_number" || fn_name == "rank" || fn_name == "dense_rank"
    -> Some(#(model.IntType, False))
    [lexer.StringLit(_), ..] -> Some(#(model.StringType, False))
    [lexer.NumberLit(n), ..] ->
      case string.contains(n, ".") {
        True -> Some(#(model.FloatType, False))
        False -> Some(#(model.IntType, False))
      }
    _ -> None
  }
}

fn extract_aggregate_inner_type(
  tokens: List(lexer.Token),
  tables: List(model.Table),
) -> Option(model.Column) {
  case tokens {
    [lexer.Ident(name), lexer.RParen, ..] | [lexer.Ident(name), lexer.Comma, ..] ->
      find_column_in_tables(tables, string.lowercase(name))
    [lexer.Ident(_table), lexer.Dot, lexer.Ident(col), lexer.RParen, ..]
    | [lexer.Ident(_table), lexer.Dot, lexer.Ident(col), lexer.Comma, ..] ->
      find_column_in_tables(tables, string.lowercase(col))
    [lexer.Keyword("distinct"), lexer.Ident(name), lexer.RParen, ..]
    | [lexer.Keyword("distinct"), lexer.Ident(name), lexer.Comma, ..] ->
      find_column_in_tables(tables, string.lowercase(name))
    _ -> None
  }
}

fn infer_cast_type(
  tokens: List(lexer.Token),
) -> Option(#(model.ScalarType, Bool)) {
  case tokens {
    [] -> None
    [lexer.Keyword("as"), lexer.Ident(type_name), ..]
    | [lexer.Keyword("as"), lexer.Keyword(type_name), ..] ->
      case model.parse_sql_type(type_name) {
        Ok(scalar_type) -> Some(#(scalar_type, True))
        Error(_) -> None
      }
    [_, ..rest] -> infer_cast_type(rest)
  }
}

fn tok_split_select_columns(
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
      tok_split_select_columns(rest, 0, [], [list.reverse(current), ..acc])
    [lexer.LParen, ..rest] ->
      tok_split_select_columns(rest, depth + 1, [lexer.LParen, ..current], acc)
    [lexer.RParen, ..rest] ->
      tok_split_select_columns(rest, depth - 1, [lexer.RParen, ..current], acc)
    [token, ..rest] ->
      tok_split_select_columns(rest, depth, [token, ..current], acc)
  }
}

/// Detect ALTER TABLE ... ADD [COLUMN] pattern.
fn is_alter_table_add_column_tokens(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [
      lexer.Keyword("alter"),
      lexer.Keyword("table"),
      _,
      lexer.Keyword("add"),
      lexer.Keyword("column"),
      ..
    ] -> True
    [
      lexer.Keyword("alter"),
      lexer.Keyword("table"),
      _,
      lexer.Keyword("add"),
      ..rest
    ] ->
      case rest {
        [lexer.Keyword(k), ..]
          if k == "constraint"
          || k == "primary"
          || k == "unique"
          || k == "foreign"
          || k == "check"
          || k == "index"
        -> False
        _ -> True
      }
    _ -> False
  }
}

/// Parse ALTER TABLE <name> ADD [COLUMN] <col_def> and apply to existing tables.
fn apply_alter_table_add_column(
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  tables: List(model.Table),
) -> Result(List(model.Table), ParseError) {
  let #(table_name, col_tokens) = extract_alter_table_parts(tokens)

  case table_name {
    "" -> Ok(tables)
    _ -> {
      use maybe_col <- result.try(parse_column_tokens(
        table_name,
        col_tokens,
        enums,
      ))
      case maybe_col {
        None -> Ok(tables)
        Some(col) ->
          Ok(
            list.map(tables, fn(t) {
              case t.name == table_name {
                True -> model.Table(..t, columns: list.append(t.columns, [col]))
                False -> t
              }
            }),
          )
      }
    }
  }
}

fn extract_alter_table_parts(
  tokens: List(lexer.Token),
) -> #(String, List(lexer.Token)) {
  case tokens {
    [
      lexer.Keyword("alter"),
      lexer.Keyword("table"),
      name_tok,
      lexer.Keyword("add"),
      lexer.Keyword("column"),
      ..rest
    ] -> #(extract_ident(name_tok), rest)
    [
      lexer.Keyword("alter"),
      lexer.Keyword("table"),
      name_tok,
      lexer.Keyword("add"),
      ..rest
    ] -> #(extract_ident(name_tok), rest)
    _ -> #("", [])
  }
}

fn extract_ident(token: lexer.Token) -> String {
  case token {
    lexer.Ident(n) -> naming.normalize_identifier(n)
    lexer.QuotedIdent(n) -> naming.normalize_identifier(n)
    _ -> ""
  }
}

fn parse_statement_tokens(
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
) -> Result(Option(model.Table), ParseError) {
  case is_create_table_tokens(tokens) {
    True -> parse_create_table_tokens(tokens, enums)
    False -> Ok(None)
  }
}

fn is_create_table_tokens(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [lexer.Keyword("create"), lexer.Keyword("table"), ..] -> True
    [
      lexer.Keyword("create"),
      lexer.Keyword("temporary"),
      lexer.Keyword("table"),
      ..
    ] -> True
    [lexer.Keyword("create"), lexer.Keyword("temp"), lexer.Keyword("table"), ..] ->
      True
    [
      lexer.Keyword("create"),
      lexer.Keyword("unlogged"),
      lexer.Keyword("table"),
      ..
    ] -> True
    _ -> False
  }
}

fn find_column_in_tables(
  tables: List(model.Table),
  column_name: String,
) -> Option(model.Column) {
  list.find_map(tables, fn(table) {
    list.find(table.columns, fn(col) {
      string.lowercase(col.name) == string.lowercase(column_name)
    })
    |> result.map_error(fn(_) { Nil })
  })
  |> option.from_result
}

fn parse_create_table_tokens(
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
) -> Result(Option(model.Table), ParseError) {
  // Find the table name: last Ident/QuotedIdent before the first LParen
  let #(header, body) = split_at_lparen(tokens, [])

  case body {
    [] ->
      Error(InvalidCreateTable(
        detail: "missing opening parenthesis in CREATE TABLE statement",
      ))
    _ -> {
      use table_name <- result.try(
        find_last_ident(header)
        |> result.map_error(fn(_) {
          InvalidCreateTable(detail: "missing table name")
        }),
      )

      // Strip trailing RParen from body
      let body_tokens = strip_trailing_rparen(body)

      use columns <- result.try(parse_columns_tokens(
        table_name,
        body_tokens,
        enums,
      ))
      Ok(Some(model.Table(name: table_name, columns:)))
    }
  }
}

/// Split tokens at the first top-level LParen. Returns (header, body_after_lparen).
fn split_at_lparen(
  tokens: List(lexer.Token),
  header: List(lexer.Token),
) -> #(List(lexer.Token), List(lexer.Token)) {
  case tokens {
    [] -> #(list.reverse(header), [])
    [lexer.LParen, ..rest] -> #(list.reverse(header), rest)
    [tok, ..rest] -> split_at_lparen(rest, [tok, ..header])
  }
}

/// Find the last Ident or QuotedIdent token in a list and return its name.
fn find_last_ident(tokens: List(lexer.Token)) -> Result(String, Nil) {
  tokens
  |> list.filter_map(fn(tok) {
    case tok {
      lexer.Ident(n) | lexer.QuotedIdent(n) ->
        Ok(naming.normalize_identifier(n))
      _ -> Error(Nil)
    }
  })
  |> list.last
}

/// Strip trailing RParen from token list.
fn strip_trailing_rparen(tokens: List(lexer.Token)) -> List(lexer.Token) {
  tokens
  |> list.reverse
  |> drop_trailing_rparens
  |> list.reverse
}

fn drop_trailing_rparens(rev_tokens: List(lexer.Token)) -> List(lexer.Token) {
  case rev_tokens {
    [lexer.RParen, ..rest] -> rest
    _ -> rev_tokens
  }
}

fn parse_columns_tokens(
  table_name: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
) -> Result(List(model.Column), ParseError) {
  split_tokens_by_comma(tokens)
  |> list.try_fold([], fn(columns, col_tokens) {
    use maybe_column <- result.try(parse_column_tokens(
      table_name,
      col_tokens,
      enums,
    ))
    Ok(case maybe_column {
      Some(column) -> [column, ..columns]
      None -> columns
    })
  })
  |> result.map(list.reverse)
}

/// Split a token list by top-level commas (depth-0 only).
fn split_tokens_by_comma(tokens: List(lexer.Token)) -> List(List(lexer.Token)) {
  split_tokens_by_comma_loop(tokens, 0, [], [])
}

fn split_tokens_by_comma_loop(
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
    [lexer.LParen, ..rest] ->
      split_tokens_by_comma_loop(
        rest,
        depth + 1,
        [lexer.LParen, ..current],
        acc,
      )
    [lexer.RParen, ..rest] ->
      split_tokens_by_comma_loop(
        rest,
        case depth > 0 {
          True -> depth - 1
          False -> 0
        },
        [lexer.RParen, ..current],
        acc,
      )
    [lexer.Comma, ..rest] if depth == 0 ->
      split_tokens_by_comma_loop(rest, depth, [], [list.reverse(current), ..acc])
    [tok, ..rest] ->
      split_tokens_by_comma_loop(rest, depth, [tok, ..current], acc)
  }
}

fn parse_column_tokens(
  table_name: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
) -> Result(Option(model.Column), ParseError) {
  case tokens {
    [] -> Ok(None)
    [first, ..rest] ->
      case first {
        lexer.Keyword("primary")
        | lexer.Keyword("foreign")
        | lexer.Keyword("unique")
        | lexer.Keyword("constraint")
        | lexer.Keyword("check") -> Ok(None)
        lexer.Ident(n) | lexer.QuotedIdent(n) -> {
          let name = naming.normalize_identifier(n)
          let type_toks = take_type_tokens_from_lexer(rest, [])

          case type_toks {
            [] ->
              Error(InvalidColumn(
                table: table_name,
                detail: "missing type for column " <> name,
              ))
            _ -> {
              let type_text = render_type_tokens(type_toks)
              let nullable = case
                tokens_contain_not_null(tokens)
                || tokens_contain_keyword(tokens, "primary")
                || string.contains(type_text, "serial")
              {
                True -> False
                False -> True
              }

              use scalar_type <- result.try(case find_enum(type_text, enums) {
                Some(enum_name) -> Ok(model.EnumType(enum_name))
                None ->
                  infer_scalar_type(type_text)
                  |> result.map_error(fn(detail) {
                    InvalidColumn(table: table_name, detail:)
                  })
              })

              Ok(Some(model.Column(name:, scalar_type:, nullable:)))
            }
          }
        }
        _ -> Ok(None)
      }
  }
}

fn take_type_tokens_from_lexer(
  tokens: List(lexer.Token),
  acc: List(lexer.Token),
) -> List(lexer.Token) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.Keyword(k), ..rest] ->
      case is_column_constraint(k) {
        True -> list.reverse(acc)
        False -> take_type_tokens_from_lexer(rest, [lexer.Keyword(k), ..acc])
      }
    [tok, ..rest] -> take_type_tokens_from_lexer(rest, [tok, ..acc])
  }
}

/// Render type tokens back to a type string for parse_sql_type lookup.
/// Handles array syntax ([] operators) by joining without spaces.
fn render_type_tokens(tokens: List(lexer.Token)) -> String {
  render_type_tokens_loop(tokens, [])
  |> list.reverse
  |> string.join(" ")
}

fn render_type_tokens_loop(
  tokens: List(lexer.Token),
  acc: List(String),
) -> List(String) {
  case tokens {
    [] -> acc
    // Collapse "[" "]" into "[]" appended to the previous token
    [lexer.Operator("["), lexer.Operator("]"), ..rest] ->
      case acc {
        [prev, ..prev_rest] ->
          render_type_tokens_loop(rest, [prev <> "[]", ..prev_rest])
        [] -> render_type_tokens_loop(rest, ["[]", ..acc])
      }
    [tok, ..rest] -> {
      let s = case tok {
        lexer.Keyword(k) -> k
        lexer.Ident(n) -> n
        lexer.QuotedIdent(n) -> n
        lexer.NumberLit(n) -> n
        lexer.Operator(op) -> op
        lexer.LParen -> "("
        lexer.RParen -> ")"
        lexer.Comma -> ","
        lexer.Star -> "*"
        _ -> ""
      }
      case s {
        "" -> render_type_tokens_loop(rest, acc)
        _ -> render_type_tokens_loop(rest, [s, ..acc])
      }
    }
  }
}

fn tokens_contain_not_null(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [] | [_] -> False
    [lexer.Keyword("not"), lexer.Keyword("null"), ..] -> True
    [_, ..rest] -> tokens_contain_not_null(rest)
  }
}

fn tokens_contain_keyword(tokens: List(lexer.Token), keyword: String) -> Bool {
  list.any(tokens, fn(tok) {
    case tok {
      lexer.Keyword(k) -> k == keyword
      _ -> False
    }
  })
}

fn infer_scalar_type(type_text: String) -> Result(model.ScalarType, String) {
  model.parse_sql_type(type_text)
  |> result.replace_error(
    "unrecognized SQL type \""
    <> type_text
    <> "\". Supported types: int, serial, float, numeric, bool, text, char, bytea,"
    <> " uuid, json, jsonb, timestamp, datetime, date, time, interval."
    <> " Hint: add a type override in sqlode.yaml under overrides.db_type",
  )
}

fn is_column_constraint(keyword: String) -> Bool {
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
      "autoincrement",
    ],
    keyword,
  )
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
