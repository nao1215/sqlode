import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, ColumnNotFound,
  CompoundColumnCountMismatch, TableNotFound,
}
import sqlode/query_analyzer/token_utils
import sqlode/runtime

type ExtractedColumn {
  ExtractedColumn(
    name: String,
    source_table: Option(String),
    expression: Option(String),
    expression_tokens: Option(List(lexer.Token)),
  )
}

pub fn infer_result_columns(
  _ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> Result(List(model.ResultColumn), AnalysisError) {
  case query.command {
    runtime.QueryExec
    | runtime.QueryExecResult
    | runtime.QueryExecRows
    | runtime.QueryExecLastId
    | runtime.QueryBatchExec
    | runtime.QueryCopyFrom -> Ok([])
    runtime.QueryOne
    | runtime.QueryMany
    | runtime.QueryBatchOne
    | runtime.QueryBatchMany -> {
      let tokens = lexer.tokenize(query.sql, engine)

      case tok_extract_returning_columns(tokens) {
        Some(returning_cols) -> {
          let table_names = token_utils.extract_table_names(tokens)
          let nullable_tables = tok_extract_nullable_tables(tokens, table_names)
          case table_names {
            [] -> Ok([])
            [primary, ..] ->
              resolve_select_columns(
                query.name,
                returning_cols,
                catalog,
                primary,
                table_names,
                nullable_tables,
              )
          }
        }
        None -> {
          let main_tokens = tok_strip_cte(tokens)
          use _ <- result.try(validate_compound_column_counts(
            query.name,
            main_tokens,
          ))
          let main_tokens2 = tok_strip_compound(main_tokens)
          let table_names = token_utils.extract_table_names(main_tokens2)
          let nullable_tables =
            tok_extract_nullable_tables(main_tokens2, table_names)

          case table_names {
            [] -> Ok([])
            [primary, ..] -> {
              let select_columns = tok_extract_select_columns(main_tokens2)
              resolve_select_columns(
                query.name,
                select_columns,
                catalog,
                primary,
                table_names,
                nullable_tables,
              )
            }
          }
        }
      }
    }
  }
}

/// Extract RETURNING columns from tokens using token-based analysis.
fn tok_extract_returning_columns(
  tokens: List(lexer.Token),
) -> Option(List(ExtractedColumn)) {
  case tok_find_returning_tokens(tokens) {
    Some(col_tokens) ->
      Some(
        token_utils.split_on_commas(col_tokens)
        |> list.map(tok_parse_column_item),
      )
    None -> None
  }
}

/// Find tokens after the RETURNING keyword until end of statement.
fn tok_find_returning_tokens(
  tokens: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case tokens {
    [] -> None
    [lexer.Keyword("returning"), ..rest] -> {
      let filtered =
        list.filter(rest, fn(tok) {
          case tok {
            lexer.Semicolon -> False
            _ -> True
          }
        })
      case filtered {
        [] -> None
        _ -> Some(filtered)
      }
    }
    [_, ..rest] -> tok_find_returning_tokens(rest)
  }
}

fn resolve_select_columns(
  query_name: String,
  columns: List(ExtractedColumn),
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
  nullable_tables: List(String),
) -> Result(List(model.ResultColumn), AnalysisError) {
  case columns {
    [ExtractedColumn(name: "*", ..)] -> {
      let result_columns =
        all_tables
        |> list.flat_map(fn(table_name) {
          case list.find(catalog.tables, fn(t) { t.name == table_name }) {
            Ok(table) ->
              list.map(table.columns, fn(col) {
                model.ResultColumn(
                  name: col.name,
                  scalar_type: col.scalar_type,
                  nullable: col.nullable
                    || list.contains(nullable_tables, table_name),
                  source_table: Some(table_name),
                )
              })
            Error(_) -> []
          }
        })
      case result_columns {
        [] -> Error(TableNotFound(query_name:, table_name: primary_table))
        _ -> Ok(result_columns)
      }
    }
    _ ->
      list.try_map(columns, fn(extracted) {
        let trimmed = string.trim(extracted.name)
        case string.starts_with(trimmed, "sqlode.embed(") {
          True -> {
            let embed_name =
              trimmed
              |> string.replace("sqlode.embed(", "")
              |> string.replace(")", "")
              |> string.trim
              |> string.lowercase

            case
              catalog.tables
              |> list.find(fn(table) { table.name == embed_name })
            {
              Ok(table) ->
                Ok([
                  model.EmbeddedColumn(
                    name: embed_name,
                    table_name: embed_name,
                    columns: table.columns,
                  ),
                ])
              Error(_) ->
                Error(TableNotFound(query_name:, table_name: embed_name))
            }
          }
          False -> {
            let normalized_name = string.lowercase(trimmed)
            case extracted.source_table {
              Some(table) ->
                case context.find_column(catalog, table, normalized_name) {
                  Some(column) ->
                    Ok([
                      model.ResultColumn(
                        name: column.name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, table),
                        source_table: Some(table),
                      ),
                    ])
                  None ->
                    case extracted.expression_tokens {
                      Some(expr_tokens) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type_from_tokens(
                            expr_tokens,
                            catalog,
                            all_tables,
                          )
                        Ok([
                          model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          ),
                        ])
                      }
                      None ->
                        Error(ColumnNotFound(
                          query_name:,
                          table_name: table,
                          column_name: normalized_name,
                        ))
                    }
                }
              None ->
                case
                  context.find_column_in_tables(
                    catalog,
                    all_tables,
                    normalized_name,
                  )
                {
                  Some(#(found_table, column)) ->
                    Ok([
                      model.ResultColumn(
                        name: column.name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, found_table),
                        source_table: Some(found_table),
                      ),
                    ])
                  None ->
                    case extracted.expression_tokens {
                      Some(expr_tokens) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type_from_tokens(
                            expr_tokens,
                            catalog,
                            all_tables,
                          )
                        Ok([
                          model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          ),
                        ])
                      }
                      None ->
                        Error(ColumnNotFound(
                          query_name:,
                          table_name: primary_table,
                          column_name: normalized_name,
                        ))
                    }
                }
            }
          }
        }
      })
      |> result.map(list.flatten)
  }
}

// ============================================================
// Token-based expression type inference (#342)
// ============================================================

fn infer_expression_type_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  case tokens {
    // count(...) -> IntType, not nullable
    [lexer.Keyword("count"), lexer.LParen, ..] -> #(model.IntType, False)

    // sum(...) -> inner type, nullable
    [lexer.Keyword("sum"), lexer.LParen, ..rest] -> {
      let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
      let first_arg = tok_first_comma_group(inner_tokens)
      let inner_type =
        resolve_column_type_from_tokens(first_arg, catalog, table_names)
      case inner_type {
        Some(t) -> #(t, True)
        None -> #(model.IntType, True)
      }
    }

    // avg(...) -> FloatType, nullable
    [lexer.Keyword("avg"), lexer.LParen, ..] -> #(model.FloatType, True)

    // min/max(...) -> inner type, nullable
    [lexer.Keyword(kw), lexer.LParen, ..rest] if kw == "min" || kw == "max" -> {
      let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
      let first_arg = tok_first_comma_group(inner_tokens)
      let inner_type =
        resolve_column_type_from_tokens(first_arg, catalog, table_names)
      case inner_type {
        Some(t) -> #(t, True)
        None -> #(model.IntType, True)
      }
    }

    // row_number(), rank(), dense_rank() -> IntType
    [lexer.Keyword(kw), lexer.LParen, ..]
      if kw == "row_number" || kw == "rank" || kw == "dense_rank"
    -> #(model.IntType, False)

    // coalesce(...) -> first arg type, not nullable
    [lexer.Keyword("coalesce"), lexer.LParen, ..rest] -> {
      let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
      let first_arg = tok_first_comma_group(inner_tokens)
      case resolve_column_type_from_tokens(first_arg, catalog, table_names) {
        Some(t) -> #(t, False)
        None -> #(model.StringType, False)
      }
    }

    // cast(expr AS type) -> parsed type, nullable
    [lexer.Keyword("cast"), lexer.LParen, ..rest] -> {
      let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
      case tok_find_as_type(inner_tokens) {
        Some(type_name) ->
          case model.parse_sql_type(type_name) {
            Ok(scalar_type) -> #(scalar_type, True)
            Error(_) -> #(model.StringType, True)
          }
        None -> #(model.StringType, True)
      }
    }

    // CASE WHEN ... THEN value ... -> examine first THEN branch
    [lexer.Keyword("case"), ..rest] ->
      infer_case_type_from_tokens(rest, catalog, table_names)

    // String literal
    [lexer.StringLit(_)] -> #(model.StringType, False)

    // Number literal
    [lexer.NumberLit(n)] ->
      case string.contains(n, ".") {
        True -> #(model.FloatType, False)
        False -> #(model.IntType, False)
      }

    // Boolean keywords
    [lexer.Keyword("true")] | [lexer.Keyword("false")] -> #(
      model.BoolType,
      False,
    )

    // Fallback: StringType, nullable
    _ -> #(model.StringType, True)
  }
}

/// Get the first comma-separated group of tokens (top-level only).
fn tok_first_comma_group(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case token_utils.split_on_commas(tokens) {
    [first, ..] -> first
    [] -> []
  }
}

/// Find the type name after AS in CAST tokens (e.g., [expr, AS, type_name]).
fn tok_find_as_type(tokens: List(lexer.Token)) -> Option(String) {
  case tokens {
    [] -> None
    [lexer.Keyword("as"), ..rest] -> {
      let type_text =
        rest
        |> list.filter_map(fn(t) {
          case t {
            lexer.Ident(n) -> Ok(n)
            lexer.Keyword(k) -> Ok(k)
            _ -> Error(Nil)
          }
        })
        |> string.join(" ")
      case type_text {
        "" -> None
        _ -> Some(string.lowercase(type_text))
      }
    }
    [_, ..rest] -> tok_find_as_type(rest)
  }
}

/// Infer type from CASE expression by examining the first THEN branch.
fn infer_case_type_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  case tok_collect_then_value(tokens) {
    Some(then_tokens) ->
      case then_tokens {
        [] -> #(model.StringType, True)
        _ -> {
          let #(scalar_type, _) =
            infer_expression_type_from_tokens(then_tokens, catalog, table_names)
          #(scalar_type, True)
        }
      }
    None -> #(model.StringType, True)
  }
}

/// Collect tokens between first THEN and the next WHEN/ELSE/END at depth 0.
fn tok_collect_then_value(
  tokens: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case tokens {
    [] -> None
    [lexer.Keyword("then"), ..rest] -> Some(tok_until_case_boundary(rest, []))
    [_, ..rest] -> tok_collect_then_value(rest)
  }
}

fn tok_until_case_boundary(
  tokens: List(lexer.Token),
  acc: List(lexer.Token),
) -> List(lexer.Token) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.Keyword(kw), ..] if kw == "when" || kw == "else" || kw == "end" ->
      list.reverse(acc)
    [token, ..rest] -> tok_until_case_boundary(rest, [token, ..acc])
  }
}

/// Resolve a column type from a token list (handles table.column and bare column).
fn resolve_column_type_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
) -> Option(model.ScalarType) {
  case tokens {
    [lexer.Ident(_table), lexer.Dot, lexer.Ident(col)] ->
      case context.find_column_in_tables(catalog, table_names, col) {
        Some(#(_, column)) -> Some(column.scalar_type)
        None -> None
      }
    [lexer.Ident(col)] ->
      case context.find_column_in_tables(catalog, table_names, col) {
        Some(#(_, column)) -> Some(column.scalar_type)
        None -> None
      }
    [lexer.Star] -> None
    _ -> None
  }
}

// ============================================================
// Token-based extraction (Phase 3 of #203)
// ============================================================

/// Strip CTE: skip everything from WITH to the main SELECT/INSERT/UPDATE/DELETE.
fn tok_strip_cte(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword("with"), ..rest] -> tok_skip_cte_defs(rest)
    _ -> tokens
  }
}

fn tok_skip_cte_defs(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [] -> []
    [lexer.Keyword(kw), ..]
      if kw == "select" || kw == "insert" || kw == "update" || kw == "delete"
    -> tokens
    [lexer.LParen, ..rest] -> {
      let remaining = token_utils.skip_parens(rest, 1)
      tok_skip_cte_defs(remaining)
    }
    [_, ..rest] -> tok_skip_cte_defs(rest)
  }
}

/// Strip compound operators (UNION, INTERSECT, EXCEPT) at depth 0.
fn tok_strip_compound(tokens: List(lexer.Token)) -> List(lexer.Token) {
  tok_strip_compound_loop(tokens, 0, [])
}

fn tok_strip_compound_loop(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> List(lexer.Token) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.LParen, ..rest] ->
      tok_strip_compound_loop(rest, depth + 1, [lexer.LParen, ..acc])
    [lexer.RParen, ..rest] ->
      tok_strip_compound_loop(rest, depth - 1, [lexer.RParen, ..acc])
    [lexer.Keyword(kw), ..] if depth == 0 -> {
      case kw == "union" || kw == "intersect" || kw == "except" {
        True -> list.reverse(acc)
        False ->
          case tokens {
            [token, ..rest] ->
              tok_strip_compound_loop(rest, depth, [token, ..acc])
            _ -> list.reverse(acc)
          }
      }
    }
    [token, ..rest] -> tok_strip_compound_loop(rest, depth, [token, ..acc])
  }
}

/// Validate that all compound query branches have the same column count.
fn validate_compound_column_counts(
  query_name: String,
  tokens: List(lexer.Token),
) -> Result(Nil, AnalysisError) {
  let branches = tok_split_compound_branches(tokens)
  case branches {
    [] | [_] -> Ok(Nil)
    [first, ..rest] -> {
      let first_count = count_branch_columns(first)
      list.try_each(rest, fn(branch) {
        let branch_count = count_branch_columns(branch)
        case branch_count == first_count {
          True -> Ok(Nil)
          False ->
            Error(CompoundColumnCountMismatch(
              query_name:,
              first_count:,
              branch_count:,
            ))
        }
      })
    }
  }
}

fn count_branch_columns(branch: List(lexer.Token)) -> Int {
  case tok_find_select_to_from(branch) {
    Some(col_tokens) -> list.length(token_utils.split_on_commas(col_tokens))
    None -> 0
  }
}

/// Split tokens on top-level compound operators (UNION, INTERSECT, EXCEPT).
fn tok_split_compound_branches(
  tokens: List(lexer.Token),
) -> List(List(lexer.Token)) {
  tok_split_compound_branches_loop(tokens, 0, [], [])
}

fn tok_split_compound_branches_loop(
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
      tok_split_compound_branches_loop(
        rest,
        depth + 1,
        [lexer.LParen, ..current],
        acc,
      )
    [lexer.RParen, ..rest] ->
      tok_split_compound_branches_loop(
        rest,
        depth - 1,
        [lexer.RParen, ..current],
        acc,
      )
    [lexer.Keyword(kw), ..rest] if depth == 0 ->
      case kw == "union" || kw == "intersect" || kw == "except" {
        True -> {
          let rest2 = case rest {
            [lexer.Keyword("all"), ..r] -> r
            _ -> rest
          }
          let branch = list.reverse(current)
          tok_split_compound_branches_loop(rest2, 0, [], [branch, ..acc])
        }
        False ->
          tok_split_compound_branches_loop(
            rest,
            depth,
            [lexer.Keyword(kw), ..current],
            acc,
          )
      }
    [token, ..rest] ->
      tok_split_compound_branches_loop(rest, depth, [token, ..current], acc)
  }
}

/// Extract nullable tables from LEFT/RIGHT/FULL JOIN keywords.
fn tok_extract_nullable_tables(
  tokens: List(lexer.Token),
  all_table_names: List(String),
) -> List(String) {
  let primary = case all_table_names {
    [p, ..] -> Some(p)
    [] -> None
  }
  let #(nullable_joined, primary_nullable) =
    tok_nullable_loop(tokens, [], False)
  case primary_nullable, primary {
    True, Some(name) -> [name, ..nullable_joined]
    _, _ -> nullable_joined
  }
}

fn tok_nullable_loop(
  tokens: List(lexer.Token),
  acc: List(String),
  primary_nullable: Bool,
) -> #(List(String), Bool) {
  case tokens {
    [] -> #(acc, primary_nullable)
    // LEFT [OUTER] JOIN table → joined table is nullable
    [lexer.Keyword("left"), ..rest] -> {
      let rest2 = tok_skip_keyword(rest, "outer")
      case rest2 {
        [lexer.Keyword("join"), ..after_join] -> {
          let #(name, remaining) = token_utils.read_table_name(after_join)
          case name {
            Some(n) ->
              tok_nullable_loop(remaining, [n, ..acc], primary_nullable)
            None -> tok_nullable_loop(remaining, acc, primary_nullable)
          }
        }
        _ -> tok_nullable_loop(rest, acc, primary_nullable)
      }
    }
    // FULL [OUTER] JOIN table → both sides nullable
    [lexer.Keyword("full"), ..rest] -> {
      let rest2 = tok_skip_keyword(rest, "outer")
      case rest2 {
        [lexer.Keyword("join"), ..after_join] -> {
          let #(name, remaining) = token_utils.read_table_name(after_join)
          case name {
            Some(n) -> tok_nullable_loop(remaining, [n, ..acc], True)
            None -> tok_nullable_loop(remaining, acc, True)
          }
        }
        _ -> tok_nullable_loop(rest, acc, primary_nullable)
      }
    }
    // RIGHT [OUTER] JOIN → primary becomes nullable
    [lexer.Keyword("right"), ..rest] -> {
      let rest2 = tok_skip_keyword(rest, "outer")
      case rest2 {
        [lexer.Keyword("join"), ..after_join] ->
          tok_nullable_loop(after_join, acc, True)
        _ -> tok_nullable_loop(rest, acc, primary_nullable)
      }
    }
    [_, ..rest] -> tok_nullable_loop(rest, acc, primary_nullable)
  }
}

fn tok_skip_keyword(tokens: List(lexer.Token), kw: String) -> List(lexer.Token) {
  case tokens {
    [lexer.Keyword(k), ..rest] if k == kw -> rest
    _ -> tokens
  }
}

/// Extract SELECT columns from tokens → List(ExtractedColumn).
fn tok_extract_select_columns(
  tokens: List(lexer.Token),
) -> List(ExtractedColumn) {
  case tok_find_select_to_from(tokens) {
    Some(col_tokens) ->
      token_utils.split_on_commas(col_tokens)
      |> list.map(tok_parse_column_item)
    None -> []
  }
}

/// Find tokens between SELECT and top-level FROM.
fn tok_find_select_to_from(
  tokens: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case tokens {
    [] -> None
    [lexer.Keyword("select"), ..rest] -> {
      // Skip DISTINCT/ALL
      let rest2 = case rest {
        [lexer.Keyword("distinct"), ..r] -> r
        [lexer.Keyword("all"), ..r] -> r
        _ -> rest
      }
      tok_collect_until_from(rest2, 0, [])
    }
    [_, ..rest] -> tok_find_select_to_from(rest)
  }
}

/// Collect tokens until top-level FROM (depth 0).
fn tok_collect_until_from(
  tokens: List(lexer.Token),
  depth: Int,
  acc: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case tokens {
    [] ->
      case acc {
        [] -> None
        _ -> Some(list.reverse(acc))
      }
    [lexer.Keyword("from"), ..] if depth == 0 ->
      case acc {
        [] -> None
        _ -> Some(list.reverse(acc))
      }
    [lexer.LParen, ..rest] ->
      tok_collect_until_from(rest, depth + 1, [lexer.LParen, ..acc])
    [lexer.RParen, ..rest] ->
      tok_collect_until_from(rest, depth - 1, [lexer.RParen, ..acc])
    [token, ..rest] -> tok_collect_until_from(rest, depth, [token, ..acc])
  }
}

/// Parse a column item from tokens into ExtractedColumn.
fn tok_parse_column_item(tokens: List(lexer.Token)) -> ExtractedColumn {
  // Check for sqlode.embed(table) pattern: Ident("sqlode") Dot Ident("embed") LParen ...
  case tokens {
    [lexer.Ident(name), lexer.Dot, lexer.Ident(fn_name), lexer.LParen, ..] -> {
      case
        string.lowercase(name) == "sqlode"
        && string.lowercase(fn_name) == "embed"
      {
        True -> {
          // Reconstruct as "sqlode.embed(table_name)" without extra spaces
          let text = tok_reconstruct_macro_call(tokens)
          ExtractedColumn(
            name: text,
            source_table: None,
            expression: None,
            expression_tokens: None,
          )
        }
        False -> tok_parse_regular_column(tokens)
      }
    }
    _ -> tok_parse_regular_column(tokens)
  }
}

/// Reconstruct sqlode.embed(table) call without extra spaces.
fn tok_reconstruct_macro_call(tokens: List(lexer.Token)) -> String {
  tokens
  |> list.map(fn(t) {
    case t {
      lexer.Ident(n) -> n
      lexer.Dot -> "."
      lexer.LParen -> "("
      lexer.RParen -> ")"
      lexer.Keyword(k) -> k
      _ -> ""
    }
  })
  |> string.concat
}

/// Parse a non-embed column item.
fn tok_parse_regular_column(tokens: List(lexer.Token)) -> ExtractedColumn {
  // Find last top-level AS
  case tok_split_on_last_as(tokens) {
    Some(#(expr_tokens, alias_tokens)) -> {
      let alias_name = tok_tokens_to_text(alias_tokens)
      let expr_text = tok_tokens_to_text(expr_tokens)
      let table = case expr_tokens {
        [lexer.Ident(t), lexer.Dot, lexer.Ident(_)] -> Some(string.lowercase(t))
        _ -> None
      }
      ExtractedColumn(
        name: alias_name,
        source_table: table,
        expression: Some(expr_text),
        expression_tokens: Some(expr_tokens),
      )
    }
    None ->
      case tokens {
        [lexer.Ident(table), lexer.Dot, lexer.Ident(col)] ->
          ExtractedColumn(
            name: col,
            source_table: Some(string.lowercase(table)),
            expression: None,
            expression_tokens: None,
          )
        [lexer.Ident(name)] ->
          ExtractedColumn(
            name: name,
            source_table: None,
            expression: None,
            expression_tokens: None,
          )
        [lexer.Star] ->
          ExtractedColumn(
            name: "*",
            source_table: None,
            expression: None,
            expression_tokens: None,
          )
        _ -> {
          let text = tok_tokens_to_text(tokens)
          ExtractedColumn(
            name: text,
            source_table: None,
            expression: Some(text),
            expression_tokens: Some(tokens),
          )
        }
      }
  }
}

/// Find last top-level AS in token list, split into (before, after).
fn tok_split_on_last_as(
  tokens: List(lexer.Token),
) -> Option(#(List(lexer.Token), List(lexer.Token))) {
  let last_idx = tok_find_last_as_idx(tokens, 0, None, 0)
  case last_idx {
    None -> None
    Some(pos) -> Some(#(list.take(tokens, pos), list.drop(tokens, pos + 1)))
  }
}

fn tok_find_last_as_idx(
  tokens: List(lexer.Token),
  depth: Int,
  last: Option(Int),
  idx: Int,
) -> Option(Int) {
  case tokens {
    [] -> last
    [lexer.LParen, ..rest] ->
      tok_find_last_as_idx(rest, depth + 1, last, idx + 1)
    [lexer.RParen, ..rest] ->
      tok_find_last_as_idx(rest, depth - 1, last, idx + 1)
    [lexer.Keyword("as"), ..rest] if depth == 0 ->
      tok_find_last_as_idx(rest, depth, Some(idx), idx + 1)
    [_, ..rest] -> tok_find_last_as_idx(rest, depth, last, idx + 1)
  }
}

fn tok_tokens_to_text(tokens: List(lexer.Token)) -> String {
  lexer.tokens_to_string(
    tokens,
    lexer.TokenRenderOptions(
      uppercase_keywords: False,
      preserve_quotes: False,
      engine: None,
    ),
  )
}
