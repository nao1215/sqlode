import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/context.{type AnalyzerContext}
import sqlode/query_analyzer/placeholder

pub fn infer_insert_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)

  case regexp.scan(ctx.insert_re, normalized) {
    [match, ..] ->
      case match.submatches {
        [Some(table_name), Some(columns_text), Some(values_text)] -> {
          let columns =
            context.split_csv(columns_text)
            |> list.map(naming.normalize_identifier)

          let values =
            context.split_csv(values_text)
            |> list.map(string.trim)

          map_insert_columns(
            engine,
            catalog,
            table_name,
            columns,
            values,
            1,
            [],
          )
          |> list.reverse
        }
        _ -> []
      }
    [] -> []
  }
}

fn map_insert_columns(
  engine: model.Engine,
  catalog: model.Catalog,
  table_name: String,
  columns: List(String),
  values: List(String),
  occurrence: Int,
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case columns, values {
    [], _ | _, [] -> acc
    [column_name, ..rest_columns], [value, ..rest_values] -> {
      let acc = case
        placeholder.placeholder_index_for_token(engine, value, occurrence)
      {
        Some(index) ->
          case context.find_column(catalog, table_name, column_name) {
            Some(column) -> [#(index, column), ..acc]
            None -> acc
          }
        None -> acc
      }

      let next_occurrence = case placeholder.is_placeholder_token(value) {
        True -> occurrence + 1
        False -> occurrence
      }

      map_insert_columns(
        engine,
        catalog,
        table_name,
        rest_columns,
        rest_values,
        next_occurrence,
        acc,
      )
    }
  }
}

pub fn infer_equality_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)
  let tokens = lexer.tokenize(query.sql, engine)
  let all_tables = tok_extract_table_names(tokens)

  case all_tables {
    [] -> []
    [primary, ..] ->
      scan_equality_matches(
        engine,
        catalog,
        primary,
        all_tables,
        regexp.scan(ctx.equality_re, normalized),
        1,
        [],
      )
      |> list.reverse
  }
}

fn scan_equality_matches(
  engine: model.Engine,
  catalog: model.Catalog,
  primary_table: String,
  all_tables: List(String),
  matches: List(regexp.Match),
  occurrence: Int,
  acc: List(#(Int, model.Column)),
) -> List(#(Int, model.Column)) {
  case matches {
    [] -> acc
    [match, ..rest] ->
      case match.submatches {
        [Some(column_ref), Some(token)] -> {
          // Handle table.column qualified references
          let #(search_table, col_name) = case
            string.split_once(column_ref, ".")
          {
            Ok(#(table_prefix, column)) -> #(
              Some(string.trim(table_prefix)),
              string.trim(column),
            )
            Error(_) -> #(None, column_ref)
          }
          let normalized_col = naming.normalize_identifier(col_name)

          let acc = case
            placeholder.placeholder_index_for_token(engine, token, occurrence)
          {
            Some(index) -> {
              let found = case search_table {
                Some(table) ->
                  context.find_column(catalog, table, normalized_col)
                None ->
                  find_column_in_tables(catalog, all_tables, normalized_col)
              }
              case found {
                Some(column) -> [#(index, column), ..acc]
                None ->
                  // Fallback: try primary table
                  case
                    context.find_column(catalog, primary_table, normalized_col)
                  {
                    Some(column) -> [#(index, column), ..acc]
                    None -> acc
                  }
              }
            }
            None -> acc
          }

          let next_occurrence = case
            placeholder.sequential_placeholder(engine)
          {
            True -> occurrence + 1
            False -> occurrence
          }

          scan_equality_matches(
            engine,
            catalog,
            primary_table,
            all_tables,
            rest,
            next_occurrence,
            acc,
          )
        }
        _ ->
          scan_equality_matches(
            engine,
            catalog,
            primary_table,
            all_tables,
            rest,
            occurrence,
            acc,
          )
      }
  }
}

pub fn infer_in_params(
  ctx: AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
) -> List(#(Int, model.Column)) {
  let normalized = context.normalize_sql(ctx, query.sql)
  let tokens = lexer.tokenize(query.sql, engine)
  let all_tables = tok_extract_table_names(tokens)

  case all_tables {
    [] -> []
    [primary, ..] ->
      scan_equality_matches(
        engine,
        catalog,
        primary,
        all_tables,
        regexp.scan(ctx.in_clause_re, normalized),
        1,
        [],
      )
      |> list.reverse
  }
}

pub fn extract_type_casts(
  ctx: AnalyzerContext,
  engine: model.Engine,
  sql: String,
) -> Result(dict.Dict(Int, model.ScalarType), #(Int, String)) {
  case engine {
    model.PostgreSQL -> {
      let normalized = context.normalize_sql(ctx, sql)
      regexp.scan(ctx.type_cast_re, normalized)
      |> list.try_fold(dict.new(), fn(d, match) {
        case match.submatches {
          [Some(ph)] -> {
            let cast_type = string.replace(match.content, ph <> "::", "")
            case
              ph
              |> string.replace("$", "")
              |> int.parse
            {
              Ok(index) ->
                case cast_type_to_scalar(cast_type) {
                  Ok(scalar_type) -> Ok(dict.insert(d, index, scalar_type))
                  Error(Nil) -> Error(#(index, string.trim(cast_type)))
                }
              Error(_) -> Ok(d)
            }
          }
          _ -> Ok(d)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

fn cast_type_to_scalar(type_name: String) -> Result(model.ScalarType, Nil) {
  model.parse_sql_type(string.trim(type_name))
}

// --- Token-based helpers ---

/// Search all tables for a column by name.
fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(model.Column) {
  list.find_map(table_names, fn(name) {
    case context.find_column(catalog, name, column_name) {
      Some(col) -> Ok(col)
      None -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Extract table names from tokens (FROM/JOIN/INTO/UPDATE).
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
    [lexer.Keyword("from"), lexer.LParen, ..rest] -> {
      let remaining = tok_skip_parens(rest, 1)
      tok_table_names_loop(remaining, acc)
    }
    [lexer.Keyword(kw), ..rest]
      if kw == "from" || kw == "into" || kw == "update"
    -> {
      let #(name, remaining) = tok_read_table_name(rest)
      case name {
        Some(n) -> tok_table_names_loop(remaining, [n, ..acc])
        None -> tok_table_names_loop(rest, acc)
      }
    }
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
