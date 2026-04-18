import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, ColumnNotFound,
  CompoundColumnCountMismatch, TableNotFound, UnsupportedExpression,
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
) -> Result(List(model.ResultItem), AnalysisError) {
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
      infer_columns_from_tokens(query.name, tokens, catalog)
    }
  }
}

/// Token-based column inference, exposed so callers (notably the CTE
/// virtual-table builder in `query_analyzer`) can reuse the SELECT
/// resolver without re-lexing or constructing a synthetic ParsedQuery.
pub fn infer_columns_from_tokens(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> Result(List(model.ResultItem), AnalysisError) {
  infer_columns_from_tokens_scoped(query_name, tokens, catalog, [])
}

/// Same as `infer_columns_from_tokens`, but when the inner query has no
/// FROM clause of its own, fall back to `outer_tables` so correlated
/// references like `SELECT (SELECT books.id)` can still be resolved
/// against the enclosing query's FROM list.
///
/// Every entry point also runs VALUES and derived-table discovery over
/// its own token scope and augments the catalog before resolution, so
/// nested subqueries pick up sibling virtual tables without extra work
/// from the caller.
pub fn infer_columns_from_tokens_scoped(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  outer_tables: List(String),
) -> Result(List(model.ResultItem), AnalysisError) {
  use augmented <- result.try(augment_with_subquery_tables(
    query_name,
    tokens,
    catalog,
  ))
  case tok_extract_returning_columns(tokens) {
    Some(returning_cols) -> {
      let table_names = token_utils.extract_table_names(tokens)
      let nullable_tables = tok_extract_nullable_tables(tokens, table_names)
      case effective_tables(table_names, outer_tables) {
        [] -> Ok([])
        [primary, ..] as tables ->
          resolve_select_columns(
            query_name,
            returning_cols,
            augmented,
            primary,
            tables,
            nullable_tables,
          )
      }
    }
    None -> {
      let main_tokens = tok_strip_cte(tokens)
      use _ <- result.try(validate_compound_column_counts(
        query_name,
        main_tokens,
      ))
      let main_tokens2 = tok_strip_compound(main_tokens)
      let table_names = token_utils.extract_table_names(main_tokens2)
      let nullable_tables =
        tok_extract_nullable_tables(main_tokens2, table_names)

      case effective_tables(table_names, outer_tables) {
        [] -> Ok([])
        [primary, ..] as tables -> {
          let select_columns = tok_extract_select_columns(main_tokens2)
          resolve_select_columns(
            query_name,
            select_columns,
            augmented,
            primary,
            tables,
            nullable_tables,
          )
        }
      }
    }
  }
}

fn augment_with_subquery_tables(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> Result(model.Catalog, AnalysisError) {
  let values = extract_values_tables(tokens)
  let with_values = augment_catalog_with(catalog, values)
  use derived <- result.try(extract_derived_tables(
    query_name,
    tokens,
    with_values,
  ))
  Ok(augment_catalog_with(with_values, derived))
}

/// Pick the scope the resolver should use: the inner FROM tables if any,
/// else the outer FROM tables (for correlated subqueries without their
/// own FROM). Returning [] preserves the pre-scope "empty -> Ok([])"
/// behaviour so callers can still detect "no columns produced".
fn effective_tables(
  inner_tables: List(String),
  outer_tables: List(String),
) -> List(String) {
  case inner_tables {
    [] -> outer_tables
    _ -> inner_tables
  }
}

/// Extract CTE definitions from a query's tokens and return the
/// resulting virtual tables. Each `name AS (body)` (or
/// `name(c1, c2) AS (body)`) becomes a Table whose columns come from
/// running infer_columns_from_tokens on the body. RECURSIVE CTEs use
/// the anchor (first) branch via the existing tok_strip_compound, so
/// recursive self-references are not analysed.
pub fn extract_cte_tables(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> Result(List(model.Table), AnalysisError) {
  case tokens {
    [lexer.Keyword("with"), lexer.Keyword("recursive"), ..rest] ->
      parse_cte_defs(query_name, rest, catalog, [])
    [lexer.Keyword("with"), ..rest] ->
      parse_cte_defs(query_name, rest, catalog, [])
    _ -> Ok([])
  }
}

fn parse_cte_defs(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  acc: List(model.Table),
) -> Result(List(model.Table), AnalysisError) {
  case tokens {
    [lexer.Ident(name), ..rest_after_name] -> {
      // Optional explicit column list: name(c1, c2, ...) AS (...).
      // When present, these names override the body's SELECT-list names.
      let #(explicit_names, after_optional_cols) = case rest_after_name {
        [lexer.LParen, ..after_lp] -> {
          let #(col_tokens, after_cols) =
            token_utils.collect_paren_contents(after_lp)
          let names = parse_cte_column_list(col_tokens)
          #(names, after_cols)
        }
        _ -> #([], rest_after_name)
      }
      case after_optional_cols {
        [lexer.Keyword("as"), lexer.LParen, ..after_as_lp] -> {
          let #(body, after_body) =
            token_utils.collect_paren_contents(after_as_lp)
          let augmented = augment_catalog_with(catalog, acc)
          use cols <- result.try(infer_columns_from_tokens(
            query_name,
            body,
            augmented,
          ))
          let body_columns =
            list.filter_map(cols, fn(item) {
              case item {
                model.ScalarResult(rc) ->
                  Ok(model.Column(
                    name: rc.name,
                    scalar_type: rc.scalar_type,
                    nullable: rc.nullable,
                  ))
                _ -> Error(Nil)
              }
            })
          let columns =
            apply_explicit_column_names(body_columns, explicit_names)
          let table =
            model.Table(name: string.lowercase(name), columns: columns)
          let new_acc = [table, ..acc]
          case after_body {
            [lexer.Comma, ..more] ->
              parse_cte_defs(query_name, more, catalog, new_acc)
            _ -> Ok(list.reverse(new_acc))
          }
        }
        _ -> Ok(list.reverse(acc))
      }
    }
    _ -> Ok(list.reverse(acc))
  }
}

/// Parse the explicit column list from `WITH name(c1, c2, ...) AS (...)`.
/// Non-ident items are skipped; empty list means no rename.
fn parse_cte_column_list(tokens: List(lexer.Token)) -> List(String) {
  token_utils.split_on_commas(tokens)
  |> list.filter_map(fn(group) {
    case group {
      [lexer.Ident(n)] -> Ok(string.lowercase(n))
      [lexer.QuotedIdent(n)] -> Ok(string.lowercase(n))
      _ -> Error(Nil)
    }
  })
}

/// Rename columns using the explicit column list, in order. Extra body
/// columns keep their original names; extra explicit names are ignored.
fn apply_explicit_column_names(
  columns: List(model.Column),
  names: List(String),
) -> List(model.Column) {
  case names {
    [] -> columns
    _ -> rename_columns(columns, names)
  }
}

fn rename_columns(
  columns: List(model.Column),
  names: List(String),
) -> List(model.Column) {
  case columns, names {
    [], _ -> []
    cols, [] -> cols
    [col, ..rest_cols], [name, ..rest_names] -> [
      model.Column(
        name: name,
        scalar_type: col.scalar_type,
        nullable: col.nullable,
      ),
      ..rename_columns(rest_cols, rest_names)
    ]
  }
}

fn augment_catalog_with(
  catalog: model.Catalog,
  vtables: List(model.Table),
) -> model.Catalog {
  case vtables {
    [] -> catalog
    _ ->
      model.Catalog(
        tables: list.append(catalog.tables, vtables),
        enums: catalog.enums,
      )
  }
}

/// Find every `(VALUES ...) AS alias(c1, c2, ...)` in the token stream
/// and build a virtual Table for each. Column types come from the first
/// row's literals; rows with unsupported expressions are skipped silently
/// (the resolver will surface any downstream issue).
pub fn extract_values_tables(tokens: List(lexer.Token)) -> List(model.Table) {
  find_values_tables(tokens, [])
}

fn find_values_tables(
  tokens: List(lexer.Token),
  acc: List(model.Table),
) -> List(model.Table) {
  case tokens {
    [] -> list.reverse(acc)
    [lexer.LParen, lexer.Keyword("values"), ..rest] -> {
      let #(values_body, after_rp) =
        token_utils.collect_paren_contents([lexer.Keyword("values"), ..rest])
      case parse_values_alias(after_rp) {
        Some(#(alias, col_names, remaining)) ->
          case infer_values_first_row_types(values_body) {
            Ok(types) -> {
              let columns = build_values_columns(col_names, types)
              let table = model.Table(name: alias, columns: columns)
              find_values_tables(remaining, [table, ..acc])
            }
            Error(_) -> find_values_tables(remaining, acc)
          }
        None -> find_values_tables(after_rp, acc)
      }
    }
    [_, ..rest] -> find_values_tables(rest, acc)
  }
}

fn parse_values_alias(
  tokens: List(lexer.Token),
) -> Option(#(String, List(String), List(lexer.Token))) {
  let after_as = case tokens {
    [lexer.Keyword("as"), ..rest] -> rest
    _ -> tokens
  }
  case after_as {
    [lexer.Ident(alias), lexer.LParen, ..rest_after_lp] -> {
      let #(col_tokens, after_cols) =
        token_utils.collect_paren_contents(rest_after_lp)
      case parse_cte_column_list(col_tokens) {
        [] -> None
        names -> Some(#(string.lowercase(alias), names, after_cols))
      }
    }
    [lexer.QuotedIdent(alias), lexer.LParen, ..rest_after_lp] -> {
      let #(col_tokens, after_cols) =
        token_utils.collect_paren_contents(rest_after_lp)
      case parse_cte_column_list(col_tokens) {
        [] -> None
        names -> Some(#(string.lowercase(alias), names, after_cols))
      }
    }
    _ -> None
  }
}

fn infer_values_first_row_types(
  values_body: List(lexer.Token),
) -> Result(List(#(model.ScalarType, Bool)), Nil) {
  // The body starts with `Keyword("values") LParen <row1> RParen, ...`
  case values_body {
    [lexer.Keyword("values"), lexer.LParen, ..rest_after_lp] -> {
      let #(first_row, _) = token_utils.collect_paren_contents(rest_after_lp)
      let items = token_utils.split_on_commas(first_row)
      list.try_map(items, infer_literal_type_with_nullability)
    }
    _ -> Error(Nil)
  }
}

fn infer_literal_type_with_nullability(
  tokens: List(lexer.Token),
) -> Result(#(model.ScalarType, Bool), Nil) {
  case tokens {
    [lexer.NumberLit(n)] -> Ok(#(number_scalar_type(n), False))
    [lexer.Operator("-"), lexer.NumberLit(n)] ->
      Ok(#(number_scalar_type(n), False))
    [lexer.Operator("+"), lexer.NumberLit(n)] ->
      Ok(#(number_scalar_type(n), False))
    [lexer.StringLit(_)] -> Ok(#(model.StringType, False))
    [lexer.Keyword("true")] | [lexer.Keyword("false")] ->
      Ok(#(model.BoolType, False))
    [lexer.Keyword("null")] -> Ok(#(model.StringType, True))
    _ -> Error(Nil)
  }
}

fn number_scalar_type(n: String) -> model.ScalarType {
  case
    string.contains(n, ".")
    || string.contains(n, "e")
    || string.contains(n, "E")
  {
    True -> model.FloatType
    False -> model.IntType
  }
}

fn build_values_columns(
  names: List(String),
  types: List(#(model.ScalarType, Bool)),
) -> List(model.Column) {
  case names, types {
    [], _ -> []
    _, [] -> []
    [name, ..rest_names], [#(st, nullable), ..rest_types] -> [
      model.Column(name: name, scalar_type: st, nullable: nullable),
      ..build_values_columns(rest_names, rest_types)
    ]
  }
}

/// Find every derived table in the token stream — `FROM (SELECT ...)`,
/// `JOIN (SELECT ...)`, `JOIN LATERAL (SELECT ...)`, and comma-LATERAL
/// `, LATERAL (SELECT ...)` — and build a virtual Table for each. Each
/// body is resolved against `catalog` via `infer_columns_from_tokens`,
/// so nested CTEs / VALUES / derived tables compose naturally. An
/// explicit `AS alias(c1, c2)` column list overrides the body's names.
pub fn extract_derived_tables(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
) -> Result(List(model.Table), AnalysisError) {
  find_derived_tables(query_name, tokens, catalog, [])
}

fn find_derived_tables(
  query_name: String,
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  acc: List(model.Table),
) -> Result(List(model.Table), AnalysisError) {
  case tokens {
    [] -> Ok(list.reverse(acc))
    [lexer.Keyword("from"), lexer.LParen, lexer.Keyword("select"), ..rest] ->
      handle_derived(query_name, rest, catalog, acc)
    [
      lexer.Keyword("join"),
      lexer.Keyword("lateral"),
      lexer.LParen,
      lexer.Keyword("select"),
      ..rest
    ] -> handle_derived(query_name, rest, catalog, acc)
    [lexer.Keyword("join"), lexer.LParen, lexer.Keyword("select"), ..rest] ->
      handle_derived(query_name, rest, catalog, acc)
    [lexer.Keyword("lateral"), lexer.LParen, lexer.Keyword("select"), ..rest] ->
      handle_derived(query_name, rest, catalog, acc)
    [_, ..rest] -> find_derived_tables(query_name, rest, catalog, acc)
  }
}

fn handle_derived(
  query_name: String,
  tokens_after_select_kw: List(lexer.Token),
  catalog: model.Catalog,
  acc: List(model.Table),
) -> Result(List(model.Table), AnalysisError) {
  let #(body, after_rp) =
    token_utils.collect_paren_contents([
      lexer.Keyword("select"),
      ..tokens_after_select_kw
    ])
  case parse_derived_alias(after_rp) {
    Some(#(alias, explicit_names, remaining)) -> {
      use cols <- result.try(infer_columns_from_tokens(
        query_name,
        body,
        catalog,
      ))
      let body_columns =
        list.filter_map(cols, fn(item) {
          case item {
            model.ScalarResult(rc) ->
              Ok(model.Column(
                name: rc.name,
                scalar_type: rc.scalar_type,
                nullable: rc.nullable,
              ))
            _ -> Error(Nil)
          }
        })
      let columns = apply_explicit_column_names(body_columns, explicit_names)
      let table = model.Table(name: alias, columns: columns)
      find_derived_tables(query_name, remaining, catalog, [table, ..acc])
    }
    None -> find_derived_tables(query_name, after_rp, catalog, acc)
  }
}

/// Parse `AS alias(c1, c2, ...)` after a derived-table subquery. The
/// column list is optional: `AS alias` alone is valid (column names
/// then come from the body). Returns the alias, any explicit names,
/// and the tokens following both.
fn parse_derived_alias(
  tokens: List(lexer.Token),
) -> Option(#(String, List(String), List(lexer.Token))) {
  let after_as = case tokens {
    [lexer.Keyword("as"), ..rest] -> rest
    _ -> tokens
  }
  case after_as {
    [lexer.Ident(alias), lexer.LParen, ..rest_after_lp] -> {
      let #(col_tokens, after_cols) =
        token_utils.collect_paren_contents(rest_after_lp)
      let names = parse_cte_column_list(col_tokens)
      Some(#(string.lowercase(alias), names, after_cols))
    }
    [lexer.QuotedIdent(alias), lexer.LParen, ..rest_after_lp] -> {
      let #(col_tokens, after_cols) =
        token_utils.collect_paren_contents(rest_after_lp)
      let names = parse_cte_column_list(col_tokens)
      Some(#(string.lowercase(alias), names, after_cols))
    }
    [lexer.Ident(alias), ..rest] -> Some(#(string.lowercase(alias), [], rest))
    [lexer.QuotedIdent(alias), ..rest] ->
      Some(#(string.lowercase(alias), [], rest))
    _ -> None
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
) -> Result(List(model.ResultItem), AnalysisError) {
  case columns {
    [ExtractedColumn(name: "*", ..)] -> {
      let result_columns =
        all_tables
        |> list.flat_map(fn(table_name) {
          case list.find(catalog.tables, fn(t) { t.name == table_name }) {
            Ok(table) ->
              list.map(table.columns, fn(col) {
                model.ScalarResult(model.ResultColumn(
                  name: col.name,
                  scalar_type: col.scalar_type,
                  nullable: col.nullable
                    || list.contains(nullable_tables, table_name),
                  source_table: Some(table_name),
                ))
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
        let lowered = string.lowercase(trimmed)
        case string.starts_with(lowered, "sqlode.embed(") {
          True -> {
            let embed_name =
              lowered
              |> string.replace("sqlode.embed(", "")
              |> string.replace(")", "")
              |> string.trim

            case
              catalog.tables
              |> list.find(fn(table) { table.name == embed_name })
            {
              Ok(table) ->
                Ok([
                  model.EmbeddedResult(model.EmbeddedColumn(
                    name: embed_name,
                    table_name: embed_name,
                    columns: table.columns,
                  )),
                ])
              Error(_) ->
                Error(TableNotFound(query_name:, table_name: embed_name))
            }
          }
          False -> {
            let normalized_name = string.lowercase(trimmed)
            // For aliased qualified refs (`t.c AS x`), the alias becomes the
            // result name but the catalog must be looked up by the real
            // column. Pull that out of expression_tokens when present.
            let qualified_lookup_column = case extracted.expression_tokens {
              Some([lexer.Ident(_), lexer.Dot, lexer.Ident(c)]) -> Some(c)
              _ -> None
            }
            case extracted.source_table {
              Some(table) -> {
                let catalog_column = case
                  context.find_column(catalog, table, normalized_name)
                {
                  Some(c) -> Some(c)
                  None ->
                    case qualified_lookup_column {
                      Some(name) -> context.find_column(catalog, table, name)
                      None -> None
                    }
                }
                case catalog_column {
                  Some(column) ->
                    Ok([
                      model.ScalarResult(model.ResultColumn(
                        name: normalized_name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, table),
                        source_table: Some(table),
                      )),
                    ])
                  None ->
                    case extracted.expression_tokens {
                      Some(expr_tokens) -> {
                        use #(scalar_type, nullable) <- result.try(
                          infer_expression_type_from_tokens(
                            expr_tokens,
                            catalog,
                            all_tables,
                            query_name,
                          ),
                        )
                        Ok([
                          model.ScalarResult(model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          )),
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
                      model.ScalarResult(model.ResultColumn(
                        name: column.name,
                        scalar_type: column.scalar_type,
                        nullable: column.nullable
                          || list.contains(nullable_tables, found_table),
                        source_table: Some(found_table),
                      )),
                    ])
                  None ->
                    case extracted.expression_tokens {
                      Some(expr_tokens) -> {
                        use #(scalar_type, nullable) <- result.try(
                          infer_expression_type_from_tokens(
                            expr_tokens,
                            catalog,
                            all_tables,
                            query_name,
                          ),
                        )
                        Ok([
                          model.ScalarResult(model.ResultColumn(
                            name: normalized_name,
                            scalar_type:,
                            nullable:,
                            source_table: None,
                          )),
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
// Token-based expression type inference (#342, #298)
// ============================================================

fn infer_expression_type_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
  query_name: String,
) -> Result(#(model.ScalarType, Bool), AnalysisError) {
  case tokens {
    // --- Type conversion (SQL reserved syntax) ---
    [lexer.Keyword("cast"), lexer.LParen, ..rest] -> {
      let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
      case tok_find_as_type(inner_tokens) {
        Some(type_name) ->
          case model.parse_sql_type(type_name) {
            Ok(scalar_type) -> Ok(#(scalar_type, True))
            Error(_) ->
              Error(UnsupportedExpression(
                query_name:,
                expression: tok_tokens_to_text(tokens),
              ))
          }
        None ->
          Error(UnsupportedExpression(
            query_name:,
            expression: tok_tokens_to_text(tokens),
          ))
      }
    }

    // --- Boolean-producing patterns (SQL reserved syntax) ---
    [lexer.Keyword("exists"), lexer.LParen, ..] -> Ok(#(model.BoolType, False))

    // --- Scalar / correlated subquery: ( SELECT ... ) ---
    // The first column of the subquery's SELECT list determines the
    // expression type. The result is nullable because the subquery
    // may return zero rows. `table_names` is passed as the outer scope
    // so a subquery without its own FROM can still resolve columns of
    // the enclosing query (e.g. `SELECT (SELECT books.id)` from books).
    [lexer.LParen, lexer.Keyword("select"), ..rest] -> {
      let #(inner, _) =
        token_utils.collect_paren_contents([lexer.Keyword("select"), ..rest])
      case
        infer_columns_from_tokens_scoped(
          query_name,
          inner,
          catalog,
          table_names,
        )
      {
        Ok([model.ScalarResult(col), ..]) -> Ok(#(col.scalar_type, True))
        _ ->
          Error(UnsupportedExpression(
            query_name:,
            expression: tok_tokens_to_text(tokens),
          ))
      }
    }

    [lexer.Keyword("not"), ..rest] ->
      infer_expression_type_from_tokens(rest, catalog, table_names, query_name)

    // --- CASE ---
    [lexer.Keyword("case"), ..rest] ->
      infer_case_type_from_tokens(rest, catalog, table_names, query_name)

    // --- REPLACE is both a keyword (CREATE OR REPLACE) and a function ---
    [lexer.Keyword("replace"), lexer.LParen, ..] ->
      Ok(#(model.StringType, False))

    // --- SQL function calls (now Ident tokens after #319) ---
    [lexer.Ident(fn_name), lexer.LParen, ..rest] -> {
      let lowered = string.lowercase(fn_name)
      case classify_function(lowered) {
        FnCount -> Ok(#(model.IntType, False))
        FnAvg -> Ok(#(model.FloatType, True))
        FnAggregateInner -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, True))
            None -> Ok(#(model.IntType, True))
          }
        }
        FnWindowInt -> Ok(#(model.IntType, False))
        FnWindowFloat -> Ok(#(model.FloatType, False))
        FnWindowFirstArg -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, True))
            None ->
              infer_expression_type_from_tokens(
                first_arg,
                catalog,
                table_names,
                query_name,
              )
              |> result.map(fn(pair) { #(pair.0, True) })
          }
        }
        FnCoalesce -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, False))
            None ->
              infer_expression_type_from_tokens(
                first_arg,
                catalog,
                table_names,
                query_name,
              )
              |> result.map(fn(pair) { #(pair.0, False) })
          }
        }
        FnGreatestLeast -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, True))
            None ->
              infer_expression_type_from_tokens(
                first_arg,
                catalog,
                table_names,
                query_name,
              )
              |> result.map(fn(pair) { #(pair.0, True) })
          }
        }
        FnString -> Ok(#(model.StringType, False))
        FnLength -> Ok(#(model.IntType, False))
        FnMath -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, False))
            None -> Ok(#(model.FloatType, False))
          }
        }
        FnDatetime -> Ok(#(infer_datetime_return_type(lowered), False))
        FnNullif -> {
          let #(inner_tokens, _) = token_utils.collect_paren_contents(rest)
          let first_arg = tok_first_comma_group(inner_tokens)
          case
            resolve_column_type_from_tokens(first_arg, catalog, table_names)
          {
            Some(t) -> Ok(#(t, True))
            None ->
              infer_expression_type_from_tokens(
                first_arg,
                catalog,
                table_names,
                query_name,
              )
              |> result.map(fn(pair) { #(pair.0, True) })
          }
        }
        FnUnknown ->
          // Unknown function call — fall through to scan-based inference
          infer_by_scanning(tokens, catalog, table_names, query_name)
      }
    }

    // --- Bare date/time identifiers (no parens) ---
    [lexer.Ident(fn_name)] -> {
      let lowered = string.lowercase(fn_name)
      case is_datetime_identifier(lowered) {
        True -> Ok(#(infer_datetime_return_type(lowered), False))
        False ->
          Error(UnsupportedExpression(
            query_name:,
            expression: tok_tokens_to_text(tokens),
          ))
      }
    }

    // --- Literals ---
    [lexer.StringLit(_)] -> Ok(#(model.StringType, False))

    [lexer.NumberLit(n)] ->
      case string.contains(n, ".") {
        True -> Ok(#(model.FloatType, False))
        False -> Ok(#(model.IntType, False))
      }

    [lexer.Keyword("true")] | [lexer.Keyword("false")] ->
      Ok(#(model.BoolType, False))

    [lexer.Keyword("null")] ->
      Error(UnsupportedExpression(
        query_name:,
        expression: tok_tokens_to_text(tokens),
      ))

    // --- Scan-based inference for compound expressions ---
    _ -> infer_by_scanning(tokens, catalog, table_names, query_name)
  }
}

// ============================================================
// Function classification helpers
// ============================================================

type FunctionClass {
  FnCount
  FnAggregateInner
  FnAvg
  FnWindowInt
  FnWindowFloat
  FnWindowFirstArg
  FnCoalesce
  FnGreatestLeast
  FnString
  FnLength
  FnMath
  FnDatetime
  FnNullif
  FnUnknown
}

fn classify_function(lowered_name: String) -> FunctionClass {
  case lowered_name {
    "count" -> FnCount
    "sum" | "min" | "max" -> FnAggregateInner
    "avg" -> FnAvg
    "row_number" | "rank" | "dense_rank" | "ntile" -> FnWindowInt
    "percent_rank" | "cume_dist" -> FnWindowFloat
    "lag" | "lead" | "first_value" | "last_value" | "nth_value" ->
      FnWindowFirstArg
    "coalesce" -> FnCoalesce
    "greatest" | "least" -> FnGreatestLeast
    "replace"
    | "lower"
    | "upper"
    | "trim"
    | "ltrim"
    | "rtrim"
    | "substr"
    | "substring"
    | "concat"
    | "reverse"
    | "lpad"
    | "rpad"
    | "left"
    | "right"
    | "repeat"
    | "initcap"
    | "translate"
    | "to_char"
    | "format"
    | "quote_literal"
    | "quote_ident"
    | "md5"
    | "encode"
    | "decode" -> FnString
    "length"
    | "char_length"
    | "character_length"
    | "octet_length"
    | "bit_length"
    | "position"
    | "strpos"
    | "ascii" -> FnLength
    "abs"
    | "round"
    | "floor"
    | "ceil"
    | "ceiling"
    | "mod"
    | "power"
    | "sqrt"
    | "sign"
    | "trunc"
    | "log"
    | "ln"
    | "exp"
    | "random"
    | "pi"
    | "degrees"
    | "radians"
    | "div" -> FnMath
    "now"
    | "current_timestamp"
    | "current_date"
    | "current_time"
    | "date"
    | "time"
    | "timestamp"
    | "date_trunc"
    | "date_part"
    | "extract"
    | "age"
    | "make_date"
    | "make_time"
    | "make_timestamp"
    | "to_timestamp"
    | "to_date"
    | "clock_timestamp"
    | "statement_timestamp"
    | "timeofday"
    | "localtime"
    | "localtimestamp" -> FnDatetime
    "nullif" | "ifnull" | "nvl" -> FnNullif
    _ -> FnUnknown
  }
}

fn is_datetime_identifier(lowered: String) -> Bool {
  case lowered {
    "now"
    | "current_timestamp"
    | "current_date"
    | "current_time"
    | "localtime"
    | "localtimestamp" -> True
    _ -> False
  }
}

fn infer_datetime_return_type(lowered: String) -> model.ScalarType {
  case lowered {
    "current_date" | "date" | "make_date" | "to_date" -> model.DateType
    "current_time" | "time" | "make_time" | "localtime" -> model.TimeType
    "date_part" | "extract" -> model.FloatType
    "to_char" -> model.StringType
    _ -> model.DateTimeType
  }
}

// ============================================================
// Scan-based inference for compound expressions
// ============================================================

type TopLevelPattern {
  PatBool
  PatConcat
  PatArithmetic
  PatJson
  PatJsonText
  PatNone
}

fn infer_by_scanning(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
  query_name: String,
) -> Result(#(model.ScalarType, Bool), AnalysisError) {
  case find_top_level_pattern(tokens) {
    PatBool -> Ok(#(model.BoolType, False))
    PatConcat -> Ok(#(model.StringType, False))
    PatArithmetic ->
      infer_arithmetic_from_tokens(tokens, catalog, table_names, query_name)
    // `->` / `#>` extract a JSON value; the result is JSON. `->>` / `#>>`
    // extract the same path but coerce to text. Both are nullable because
    // the path/key may be absent.
    PatJson -> Ok(#(model.JsonType, True))
    PatJsonText -> Ok(#(model.StringType, True))
    PatNone ->
      Error(UnsupportedExpression(
        query_name:,
        expression: tok_tokens_to_text(tokens),
      ))
  }
}

/// Infer the type of an arithmetic expression by looking at each operand
/// instead of assuming `IntType`. Integer/float mixing promotes to
/// `FloatType`; any operand being nullable makes the result nullable.
fn infer_arithmetic_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
  query_name: String,
) -> Result(#(model.ScalarType, Bool), AnalysisError) {
  let operands = split_arithmetic_operands(tokens)
  use atom_types <- result.try(
    list.try_map(operands, fn(operand_tokens) {
      infer_atom_type(operand_tokens, catalog, table_names, query_name)
    }),
  )
  case unify_types_nullable(atom_types) {
    Ok(Some(result_type)) -> Ok(result_type)
    Ok(None) ->
      Error(UnsupportedExpression(
        query_name:,
        expression: tok_tokens_to_text(tokens),
      ))
    Error(Nil) ->
      Error(UnsupportedExpression(
        query_name:,
        expression: tok_tokens_to_text(tokens),
      ))
  }
}

/// Split tokens at top-level `+`, `-`, `*`, `/` operators, respecting
/// parentheses and skipping unary `-` / `+` that appear at the start of
/// the expression or directly after another operator/keyword/`(`.
fn split_arithmetic_operands(
  tokens: List(lexer.Token),
) -> List(List(lexer.Token)) {
  split_arithmetic_loop(tokens, 0, None, [], [])
  |> list.reverse
  |> list.filter(fn(operand) { operand != [] })
}

fn split_arithmetic_loop(
  tokens: List(lexer.Token),
  depth: Int,
  prev: Option(lexer.Token),
  current: List(lexer.Token),
  acc: List(List(lexer.Token)),
) -> List(List(lexer.Token)) {
  case tokens {
    [] -> [list.reverse(current), ..acc]
    [lexer.LParen as t, ..rest] ->
      split_arithmetic_loop(rest, depth + 1, Some(t), [t, ..current], acc)
    [lexer.RParen as t, ..rest] ->
      split_arithmetic_loop(rest, depth - 1, Some(t), [t, ..current], acc)
    [lexer.Operator(op) as t, ..rest]
      if depth == 0 && { op == "+" || op == "-" || op == "*" || op == "/" }
    -> {
      case is_unary_context(prev) {
        True -> split_arithmetic_loop(rest, depth, Some(t), [t, ..current], acc)
        False ->
          split_arithmetic_loop(rest, depth, Some(t), [], [
            list.reverse(current),
            ..acc
          ])
      }
    }
    [lexer.Star as t, ..rest] if depth == 0 ->
      split_arithmetic_loop(rest, depth, Some(t), [], [
        list.reverse(current),
        ..acc
      ])
    [t, ..rest] ->
      split_arithmetic_loop(rest, depth, Some(t), [t, ..current], acc)
  }
}

fn is_unary_context(prev: Option(lexer.Token)) -> Bool {
  case prev {
    None -> True
    Some(lexer.LParen) -> True
    Some(lexer.Operator(_)) -> True
    Some(lexer.Keyword(_)) -> True
    Some(lexer.Comma) -> True
    _ -> False
  }
}

/// Infer a single operand's type+nullability. A `NULL` literal contributes
/// no type but does make the result nullable, so we return `Option(Type)`
/// so the caller can unify with other operands.
fn infer_atom_type(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
  query_name: String,
) -> Result(#(Option(model.ScalarType), Bool), AnalysisError) {
  case tokens {
    [lexer.Keyword("null")] -> Ok(#(None, True))
    _ ->
      case
        resolve_column_type_nullable_from_tokens(tokens, catalog, table_names)
      {
        Some(#(t, nullable)) -> Ok(#(Some(t), nullable))
        None ->
          infer_expression_type_from_tokens(
            tokens,
            catalog,
            table_names,
            query_name,
          )
          |> result.map(fn(pair) { #(Some(pair.0), pair.1) })
      }
  }
}

/// Combine a list of operand types into a single result type+nullability.
/// Numeric operands promote `Int` + `Float` to `Float`. Any other type
/// mismatch returns `Error(Nil)` so the caller can surface it as an
/// unsupported expression. `Ok(None)` means every operand was `NULL` and
/// no concrete type could be inferred.
fn unify_types_nullable(
  items: List(#(Option(model.ScalarType), Bool)),
) -> Result(Option(#(model.ScalarType, Bool)), Nil) {
  case items {
    [] -> Ok(None)
    [#(t, nullable), ..rest] ->
      unify_types_loop(rest, t, nullable)
      |> result.map(fn(pair) {
        case pair.0 {
          Some(scalar_type) -> Some(#(scalar_type, pair.1))
          None -> None
        }
      })
  }
}

fn unify_types_loop(
  items: List(#(Option(model.ScalarType), Bool)),
  acc_type: Option(model.ScalarType),
  acc_nullable: Bool,
) -> Result(#(Option(model.ScalarType), Bool), Nil) {
  case items {
    [] -> Ok(#(acc_type, acc_nullable))
    [#(next_type, next_nullable), ..rest] -> {
      let merged_nullable = acc_nullable || next_nullable
      case merge_scalar_types(acc_type, next_type) {
        Ok(merged_type) -> unify_types_loop(rest, merged_type, merged_nullable)
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn merge_scalar_types(
  a: Option(model.ScalarType),
  b: Option(model.ScalarType),
) -> Result(Option(model.ScalarType), Nil) {
  case a, b {
    None, other -> Ok(other)
    other, None -> Ok(other)
    Some(model.IntType), Some(model.IntType) -> Ok(Some(model.IntType))
    Some(model.FloatType), Some(model.FloatType) -> Ok(Some(model.FloatType))
    Some(model.IntType), Some(model.FloatType) -> Ok(Some(model.FloatType))
    Some(model.FloatType), Some(model.IntType) -> Ok(Some(model.FloatType))
    Some(x), Some(y) ->
      case x == y {
        True -> Ok(Some(x))
        False -> Error(Nil)
      }
  }
}

/// Like `resolve_column_type_from_tokens` but also returns the column's
/// nullability so callers can propagate `NULL`-ness through expressions.
fn resolve_column_type_nullable_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
) -> Option(#(model.ScalarType, Bool)) {
  case tokens {
    [lexer.Ident(_table), lexer.Dot, lexer.Ident(col)] ->
      case context.find_column_in_tables(catalog, table_names, col) {
        Some(#(_, column)) -> Some(#(column.scalar_type, column.nullable))
        None -> None
      }
    [lexer.Ident(col)] ->
      case context.find_column_in_tables(catalog, table_names, col) {
        Some(#(_, column)) -> Some(#(column.scalar_type, column.nullable))
        None -> None
      }
    _ -> None
  }
}

fn find_top_level_pattern(tokens: List(lexer.Token)) -> TopLevelPattern {
  find_pattern_loop(tokens, 0, PatNone)
}

fn find_pattern_loop(
  tokens: List(lexer.Token),
  depth: Int,
  found: TopLevelPattern,
) -> TopLevelPattern {
  case tokens {
    [] -> found
    [lexer.LParen, ..rest] -> find_pattern_loop(rest, depth + 1, found)
    [lexer.RParen, ..rest] -> find_pattern_loop(rest, depth - 1, found)
    [token, ..rest] if depth == 0 -> {
      case classify_top_level_token(token) {
        PatBool -> PatBool
        PatJson ->
          find_pattern_loop(rest, depth, case found {
            PatNone -> PatJson
            _ -> found
          })
        PatJsonText ->
          find_pattern_loop(rest, depth, case found {
            PatNone -> PatJsonText
            _ -> found
          })
        PatConcat ->
          find_pattern_loop(rest, depth, case found {
            PatNone -> PatConcat
            _ -> found
          })
        PatArithmetic ->
          find_pattern_loop(rest, depth, case found {
            PatNone -> PatArithmetic
            _ -> found
          })
        PatNone -> find_pattern_loop(rest, depth, found)
      }
    }
    [_, ..rest] -> find_pattern_loop(rest, depth, found)
  }
}

fn classify_top_level_token(token: lexer.Token) -> TopLevelPattern {
  case token {
    lexer.Operator(op)
      if op == "="
      || op == "!="
      || op == "<>"
      || op == "<"
      || op == ">"
      || op == "<="
      || op == ">="
      || op == "@>"
      || op == "<@"
      || op == "?|"
      || op == "?&"
      || op == "&&"
    -> PatBool
    lexer.Keyword(kw)
      if kw == "and"
      || kw == "or"
      || kw == "between"
      || kw == "in"
      || kw == "like"
      || kw == "ilike"
      || kw == "is"
      || kw == "not"
      || kw == "exists"
    -> PatBool
    lexer.Operator(op) if op == "->>" || op == "#>>" -> PatJsonText
    lexer.Operator(op) if op == "->" || op == "#>" -> PatJson
    lexer.Operator("||") -> PatConcat
    lexer.Operator(op) if op == "+" || op == "-" || op == "*" || op == "/" ->
      PatArithmetic
    // The lexer emits `Star` (not `Operator("*")`) for `*`, so an
    // expression like `price * quantity` reaches here with a Star token.
    // Inside an expression context the wildcard has already been
    // stripped away, so any Star at this point is multiplication.
    lexer.Star -> PatArithmetic
    _ -> PatNone
  }
}

// ============================================================
// Expression helpers
// ============================================================

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

/// Infer the type of a CASE expression by inspecting every THEN branch and
/// the ELSE clause (if present), unifying the branch types, and honoring
/// the nullability of each branch. `tokens` must start right after the
/// outer `CASE` keyword. Nested CASE expressions and parenthesized
/// sub-expressions inside branches are handled by tracking independent
/// `case_depth` and `paren_depth` counters.
fn infer_case_type_from_tokens(
  tokens: List(lexer.Token),
  catalog: model.Catalog,
  table_names: List(String),
  query_name: String,
) -> Result(#(model.ScalarType, Bool), AnalysisError) {
  let #(then_branches, else_branch) = collect_case_branches(tokens)
  case then_branches {
    [] ->
      Error(UnsupportedExpression(
        query_name:,
        expression: tok_tokens_to_text(tokens),
      ))
    _ -> {
      let branch_tokens = case else_branch {
        Some(e) -> list.append(then_branches, [e])
        None -> then_branches
      }
      use atom_types <- result.try(
        list.try_map(branch_tokens, fn(branch) {
          infer_atom_type(branch, catalog, table_names, query_name)
        }),
      )
      case unify_types_nullable(atom_types) {
        Ok(Some(#(scalar_type, branches_nullable))) -> {
          let nullable = case else_branch {
            Some(_) -> branches_nullable
            None -> True
          }
          Ok(#(scalar_type, nullable))
        }
        Ok(None) ->
          Error(UnsupportedExpression(
            query_name:,
            expression: tok_tokens_to_text(tokens),
          ))
        Error(Nil) ->
          Error(UnsupportedExpression(
            query_name:,
            expression: tok_tokens_to_text(tokens),
          ))
      }
    }
  }
}

type CaseCollectorMode {
  Scanning
  InThen
  InElse
}

/// Walk tokens that start right after the outer `CASE` keyword, returning
/// the raw token list of each top-level THEN branch and the ELSE branch
/// (if any). Independent counters track parentheses and nested CASE
/// expressions so that `WHEN`/`THEN`/`ELSE`/`END` are only treated as
/// boundaries at the outermost level.
fn collect_case_branches(
  tokens: List(lexer.Token),
) -> #(List(List(lexer.Token)), Option(List(lexer.Token))) {
  collect_case_loop(tokens, 0, 0, Scanning, [], [], None)
}

fn collect_case_loop(
  tokens: List(lexer.Token),
  paren_depth: Int,
  case_depth: Int,
  mode: CaseCollectorMode,
  acc: List(lexer.Token),
  then_branches_rev: List(List(lexer.Token)),
  else_branch: Option(List(lexer.Token)),
) -> #(List(List(lexer.Token)), Option(List(lexer.Token))) {
  case tokens {
    [] -> {
      let #(then_branches_rev, else_branch) =
        flush_current_branch(mode, acc, then_branches_rev, else_branch)
      #(list.reverse(then_branches_rev), else_branch)
    }
    [first, ..rest] -> {
      let in_branch = case mode {
        Scanning -> False
        _ -> True
      }
      let at_top = paren_depth == 0 && case_depth == 0
      case first {
        lexer.LParen ->
          collect_case_loop(
            rest,
            paren_depth + 1,
            case_depth,
            mode,
            append_if_in_branch(first, acc, in_branch),
            then_branches_rev,
            else_branch,
          )
        lexer.RParen ->
          collect_case_loop(
            rest,
            paren_depth - 1,
            case_depth,
            mode,
            append_if_in_branch(first, acc, in_branch),
            then_branches_rev,
            else_branch,
          )
        lexer.Keyword("case") ->
          collect_case_loop(
            rest,
            paren_depth,
            case_depth + 1,
            mode,
            append_if_in_branch(first, acc, in_branch),
            then_branches_rev,
            else_branch,
          )
        lexer.Keyword("end") if at_top -> {
          let #(then_branches_rev, else_branch) =
            flush_current_branch(mode, acc, then_branches_rev, else_branch)
          #(list.reverse(then_branches_rev), else_branch)
        }
        lexer.Keyword("end") ->
          collect_case_loop(
            rest,
            paren_depth,
            case_depth - 1,
            mode,
            append_if_in_branch(first, acc, in_branch),
            then_branches_rev,
            else_branch,
          )
        lexer.Keyword("when") if at_top -> {
          let #(then_branches_rev, else_branch) =
            flush_current_branch(mode, acc, then_branches_rev, else_branch)
          collect_case_loop(
            rest,
            paren_depth,
            case_depth,
            Scanning,
            [],
            then_branches_rev,
            else_branch,
          )
        }
        lexer.Keyword("then") if at_top ->
          collect_case_loop(
            rest,
            paren_depth,
            case_depth,
            InThen,
            [],
            then_branches_rev,
            else_branch,
          )
        lexer.Keyword("else") if at_top -> {
          let #(then_branches_rev, else_branch) =
            flush_current_branch(mode, acc, then_branches_rev, else_branch)
          collect_case_loop(
            rest,
            paren_depth,
            case_depth,
            InElse,
            [],
            then_branches_rev,
            else_branch,
          )
        }
        _ ->
          collect_case_loop(
            rest,
            paren_depth,
            case_depth,
            mode,
            append_if_in_branch(first, acc, in_branch),
            then_branches_rev,
            else_branch,
          )
      }
    }
  }
}

fn append_if_in_branch(
  token: lexer.Token,
  acc: List(lexer.Token),
  in_branch: Bool,
) -> List(lexer.Token) {
  case in_branch {
    True -> [token, ..acc]
    False -> acc
  }
}

fn flush_current_branch(
  mode: CaseCollectorMode,
  acc: List(lexer.Token),
  then_branches_rev: List(List(lexer.Token)),
  else_branch: Option(List(lexer.Token)),
) -> #(List(List(lexer.Token)), Option(List(lexer.Token))) {
  case mode {
    InThen -> #([list.reverse(acc), ..then_branches_rev], else_branch)
    InElse -> #(then_branches_rev, Some(list.reverse(acc)))
    Scanning -> #(then_branches_rev, else_branch)
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
      // Skip DISTINCT / DISTINCT ON (...) / ALL
      let rest2 = case rest {
        [
          lexer.Keyword("distinct"),
          lexer.Keyword("on"),
          lexer.LParen,
          ..after_on
        ] -> token_utils.skip_parens(after_on, 1)
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
