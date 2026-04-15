import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{
  type AnalysisError, type AnalyzerContext, ColumnNotFound,
  CompoundColumnCountMismatch, TableNotFound,
}
import sqlode/runtime

type ExtractedColumn {
  ExtractedColumn(
    name: String,
    source_table: Option(String),
    expression: Option(String),
  )
}

pub fn infer_result_columns(
  ctx: AnalyzerContext,
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
      let normalized = context.normalize_sql(ctx, query.sql)

      // RETURNING clause still uses regex (works well, no subquery risk)
      case extract_returning_columns(ctx, normalized) {
        Some(returning_cols) -> {
          let table_names = tok_extract_table_names(tokens)
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
          let table_names = tok_extract_table_names(main_tokens2)
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

fn extract_returning_columns(
  ctx: AnalyzerContext,
  sql: String,
) -> Option(List(ExtractedColumn)) {
  case regexp.scan(ctx.returning_re, sql) {
    [match, ..] ->
      case match.submatches {
        [Some(columns_text)] -> {
          let cols = case string.trim(columns_text) == "*" {
            True -> [
              ExtractedColumn(name: "*", source_table: None, expression: None),
            ]
            False ->
              context.split_csv(columns_text)
              |> list.map(fn(c) {
                ExtractedColumn(
                  name: string.trim(c),
                  source_table: None,
                  expression: None,
                )
              })
          }
          Some(cols)
        }
        _ -> None
      }
    [] -> None
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
                    case extracted.expression {
                      Some(expr) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type(expr, catalog, all_tables)
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
                  find_column_in_tables(catalog, all_tables, normalized_name)
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
                    case extracted.expression {
                      Some(expr) -> {
                        let #(scalar_type, nullable) =
                          infer_expression_type(expr, catalog, all_tables)
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

fn infer_expression_type(
  expr: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  let lowered = string.lowercase(string.trim(expr))
  infer_expression_type_dispatch(lowered, catalog, table_names)
}

fn infer_expression_type_dispatch(
  lowered: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  let prefixes = [
    #("count(", InferCount),
    #("sum(", InferSum),
    #("avg(", InferAvg),
    #("min(", InferMinMax),
    #("max(", InferMinMax),
    #("row_number(", InferRowNumber),
    #("rank(", InferRowNumber),
    #("dense_rank(", InferRowNumber),
    #("coalesce(", InferCoalesce),
    #("cast(", InferCast),
    #("case ", InferCase),
    #("'", InferStringLiteral),
  ]
  case find_matching_prefix(lowered, prefixes) {
    Some(InferCount) -> #(model.IntType, False)
    Some(InferSum) -> {
      let inner_type = infer_aggregate_inner_type(lowered, catalog, table_names)
      #(inner_type, True)
    }
    Some(InferAvg) -> #(model.FloatType, True)
    Some(InferMinMax) -> {
      let inner_type = infer_aggregate_inner_type(lowered, catalog, table_names)
      #(inner_type, True)
    }
    Some(InferRowNumber) -> #(model.IntType, False)
    Some(InferCoalesce) -> {
      let inner = extract_function_arg(lowered)
      case resolve_column_type(string.trim(inner), catalog, table_names) {
        Some(t) -> #(t, False)
        None -> #(model.StringType, False)
      }
    }
    Some(InferCast) ->
      case string.split_once(lowered, " as ") {
        Ok(#(_, type_part)) -> {
          let type_text = type_part |> string.replace(")", "") |> string.trim
          case model.parse_sql_type(type_text) {
            Ok(scalar_type) -> #(scalar_type, True)
            Error(_) -> #(model.StringType, True)
          }
        }
        Error(_) -> #(model.StringType, True)
      }
    Some(InferCase) -> infer_case_type(lowered, catalog, table_names)
    Some(InferStringLiteral) -> #(model.StringType, False)
    None ->
      case is_integer_literal(lowered) {
        True -> #(model.IntType, False)
        False ->
          case lowered == "true" || lowered == "false" {
            True -> #(model.BoolType, False)
            False -> #(model.StringType, True)
          }
      }
  }
}

type ExprKind {
  InferCount
  InferSum
  InferAvg
  InferMinMax
  InferRowNumber
  InferCoalesce
  InferCast
  InferCase
  InferStringLiteral
}

fn find_matching_prefix(
  lowered: String,
  rules: List(#(String, ExprKind)),
) -> Option(ExprKind) {
  case rules {
    [] -> None
    [#(prefix, kind), ..rest] ->
      case string.starts_with(lowered, prefix) {
        True -> Some(kind)
        False -> find_matching_prefix(lowered, rest)
      }
  }
}

fn infer_aggregate_inner_type(
  func_expr: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> model.ScalarType {
  let inner = extract_function_arg(func_expr)
  case resolve_column_type(string.trim(inner), catalog, table_names) {
    Some(t) -> t
    None -> model.IntType
  }
}

fn extract_function_arg(func_expr: String) -> String {
  case string.split_once(func_expr, "(") {
    Ok(#(_, rest)) -> {
      let arg = extract_paren_content(string.to_graphemes(rest), 1, [])
      // For multi-arg functions, take the first top-level arg
      let first_arg = extract_first_csv_arg(string.to_graphemes(arg), 0, [])
      string.trim(first_arg)
    }
    Error(_) -> func_expr
  }
}

/// Extract content between matched parentheses, tracking depth.
fn extract_paren_content(
  chars: List(String),
  depth: Int,
  acc: List(String),
) -> String {
  case depth <= 0 {
    True -> acc |> list.reverse |> string.concat
    False ->
      case chars {
        [] -> acc |> list.reverse |> string.concat
        ["(", ..rest] -> extract_paren_content(rest, depth + 1, ["(", ..acc])
        [")", ..rest] ->
          case depth == 1 {
            True -> acc |> list.reverse |> string.concat
            False -> extract_paren_content(rest, depth - 1, [")", ..acc])
          }
        [c, ..rest] -> extract_paren_content(rest, depth, [c, ..acc])
      }
  }
}

/// Extract first comma-separated argument at top level (not inside parens).
fn extract_first_csv_arg(
  chars: List(String),
  depth: Int,
  acc: List(String),
) -> String {
  case chars {
    [] -> acc |> list.reverse |> string.concat
    ["(", ..rest] -> extract_first_csv_arg(rest, depth + 1, ["(", ..acc])
    [")", ..rest] -> extract_first_csv_arg(rest, depth - 1, [")", ..acc])
    [",", ..] if depth == 0 -> acc |> list.reverse |> string.concat
    [c, ..rest] -> extract_first_csv_arg(rest, depth, [c, ..acc])
  }
}

/// Infer type from CASE expression by examining the first THEN branch.
fn infer_case_type(
  lowered: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> #(model.ScalarType, Bool) {
  // Extract the first THEN value from "case when ... then <value> ..."
  case string.split_once(lowered, " then ") {
    Ok(#(_, after_then)) -> {
      // The value extends until WHEN, ELSE, or END
      let value_text =
        after_then
        |> split_before_keyword([" when ", " else ", " end"])
        |> string.trim
      case value_text {
        "" -> #(model.StringType, True)
        _ ->
          infer_expression_type_dispatch(value_text, catalog, table_names)
          |> fn(result) { #(result.0, True) }
      }
    }
    Error(_) -> #(model.StringType, True)
  }
}

/// Split string before the first occurrence of any keyword.
fn split_before_keyword(s: String, keywords: List(String)) -> String {
  case keywords {
    [] -> s
    [kw, ..rest] ->
      case string.split_once(s, kw) {
        Ok(#(before, _)) -> split_before_keyword(before, rest)
        Error(_) -> split_before_keyword(s, rest)
      }
  }
}

fn resolve_column_type(
  name: String,
  catalog: model.Catalog,
  table_names: List(String),
) -> Option(model.ScalarType) {
  // Try table.column format
  let col_name = case string.split_once(name, ".") {
    Ok(#(_, col)) -> string.trim(col)
    Error(_) -> name
  }
  case find_column_in_tables(catalog, table_names, col_name) {
    Some(#(_, column)) -> Some(column.scalar_type)
    None -> None
  }
}

fn is_integer_literal(s: String) -> Bool {
  !string.is_empty(s)
  && string.to_utf_codepoints(s)
  |> list.all(fn(cp) {
    let value = string.utf_codepoint_to_int(cp)
    value >= 48 && value <= 57
  })
}

fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(#(String, model.Column)) {
  list.find_map(table_names, fn(name) {
    case context.find_column(catalog, name, column_name) {
      Some(col) -> Ok(#(name, col))
      None -> Error(Nil)
    }
  })
  |> option.from_result
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
      let remaining = tok_skip_parens(rest, 1)
      tok_skip_cte_defs(remaining)
    }
    [_, ..rest] -> tok_skip_cte_defs(rest)
  }
}

/// Skip tokens until matching closing paren.
fn tok_skip_parens(tokens: List(lexer.Token), depth: Int) -> List(lexer.Token) {
  case depth <= 0 {
    True -> tokens
    False ->
      case tokens {
        [] -> []
        [lexer.LParen, ..rest] -> tok_skip_parens(rest, depth + 1)
        [lexer.RParen, ..rest] -> tok_skip_parens(rest, depth - 1)
        [_, ..rest] -> tok_skip_parens(rest, depth)
      }
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
    Some(col_tokens) -> list.length(tok_split_on_commas(col_tokens))
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

/// Extract table names from FROM/JOIN/INTO/UPDATE keywords.
fn tok_extract_table_names(tokens: List(lexer.Token)) -> List(String) {
  tok_table_names_loop(tokens, [])
  |> list.unique
}

fn tok_table_names_loop(
  tokens: List(lexer.Token),
  acc: List(String),
) -> List(String) {
  case tokens {
    [] -> list.reverse(acc)
    // FROM (SELECT ...) — skip subquery
    [lexer.Keyword("from"), lexer.LParen, ..rest] -> {
      let remaining = tok_skip_parens(rest, 1)
      tok_table_names_loop(remaining, acc)
    }
    // FROM table, INTO table, UPDATE table
    [lexer.Keyword(kw), ..rest]
      if kw == "from" || kw == "into" || kw == "update"
    -> {
      let #(name, remaining) = tok_read_table_name(rest)
      case name {
        Some(n) -> tok_table_names_loop(remaining, [n, ..acc])
        None -> tok_table_names_loop(rest, acc)
      }
    }
    // JOIN table (possibly preceded by LEFT/RIGHT/FULL/INNER/CROSS + OUTER)
    [lexer.Keyword("join"), ..rest] -> {
      let #(name, remaining) = tok_read_table_name(rest)
      case name {
        Some(n) -> tok_table_names_loop(remaining, [n, ..acc])
        None -> tok_table_names_loop(rest, acc)
      }
    }
    [_, ..rest] -> tok_table_names_loop(rest, acc)
  }
}

/// Read the next table name (handling schema.table → last part).
fn tok_read_table_name(
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
      let remaining = tok_skip_parens(rest, 1)
      #(None, remaining)
    }
    _ -> #(None, tokens)
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
          let #(name, remaining) = tok_read_table_name(after_join)
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
          let #(name, remaining) = tok_read_table_name(after_join)
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
      tok_split_on_commas(col_tokens)
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

/// Split tokens on top-level commas.
fn tok_split_on_commas(tokens: List(lexer.Token)) -> List(List(lexer.Token)) {
  tok_split_commas_loop(tokens, 0, [], [])
}

fn tok_split_commas_loop(
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
        [] -> tok_split_commas_loop(rest, 0, [], acc)
        _ -> tok_split_commas_loop(rest, 0, [], [list.reverse(current), ..acc])
      }
    [lexer.LParen, ..rest] ->
      tok_split_commas_loop(rest, depth + 1, [lexer.LParen, ..current], acc)
    [lexer.RParen, ..rest] ->
      tok_split_commas_loop(rest, depth - 1, [lexer.RParen, ..current], acc)
    [token, ..rest] ->
      tok_split_commas_loop(rest, depth, [token, ..current], acc)
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
          ExtractedColumn(name: text, source_table: None, expression: None)
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
      )
    }
    None ->
      case tokens {
        [lexer.Ident(table), lexer.Dot, lexer.Ident(col)] ->
          ExtractedColumn(
            name: col,
            source_table: Some(string.lowercase(table)),
            expression: None,
          )
        [lexer.Ident(name)] ->
          ExtractedColumn(name: name, source_table: None, expression: None)
        [lexer.Star] ->
          ExtractedColumn(name: "*", source_table: None, expression: None)
        _ -> {
          let text = tok_tokens_to_text(tokens)
          ExtractedColumn(
            name: text,
            source_table: None,
            expression: Some(text),
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
    lexer.TokenRenderOptions(uppercase_keywords: False, preserve_quotes: False),
  )
}
