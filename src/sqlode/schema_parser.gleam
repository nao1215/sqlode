import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/token_utils

pub type ParseError {
  InvalidCreateTable(path: String, detail: String)
  InvalidColumn(path: String, table: String, detail: String)
  /// Issue #419: emitted when a MySQL schema file contains a DDL
  /// statement sqlode does not yet understand, instead of silently
  /// dropping it on the floor. The detail names the leading
  /// keywords of the offending statement so the user can tell at a
  /// glance which line triggered the failure.
  UnsupportedMysqlDdl(path: String, detail: String)
}

pub type SchemaWarning {
  UnresolvableViewColumn(column: String)
}

type ParsedSchema {
  ParsedSchema(
    tables: List(model.Table),
    enums: List(model.EnumDef),
    warnings: List(SchemaWarning),
  )
}

type ViewColumn {
  ViewColumn(name: String, expr_tokens: List(lexer.Token))
}

pub fn parse_files(
  entries: List(#(String, String)),
) -> Result(#(model.Catalog, List(SchemaWarning)), ParseError) {
  parse_files_with_engine(entries, model.PostgreSQL)
}

pub fn parse_files_with_engine(
  entries: List(#(String, String)),
  engine: model.Engine,
) -> Result(#(model.Catalog, List(SchemaWarning)), ParseError) {
  entries
  |> list.try_fold(
    ParsedSchema(tables: [], enums: [], warnings: []),
    fn(acc, entry) {
      let #(path, content) = entry
      use parsed <- result.try(parse_content(
        path,
        content,
        acc.tables,
        acc.enums,
        engine,
      ))
      Ok(ParsedSchema(
        tables: parsed.tables,
        enums: parsed.enums,
        warnings: list.append(acc.warnings, parsed.warnings),
      ))
    },
  )
  |> result.map(fn(schema) {
    #(
      model.Catalog(tables: schema.tables, enums: schema.enums),
      schema.warnings,
    )
  })
}

/// Parse a single schema file. Accepts the catalog accumulated from
/// previously-parsed files so migration-history fixtures that split
/// CREATE TABLE and later ALTER statements across files can still
/// apply the ALTERs against the real table list.
fn parse_content(
  path: String,
  content: String,
  existing_tables: List(model.Table),
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

  // Seed the fold with tables from earlier files in reverse, matching
  // the newest-first convention used inside the fold; the final
  // `list.reverse` restores declaration order.
  let initial_tables = list.reverse(existing_tables)

  use #(tables, final_enums, warnings) <- result.try(
    statements
    |> list.try_fold(#(initial_tables, all_enums, []), fn(acc, stmt_tokens) {
      let #(tables, current_enums, warnings) = acc
      case is_create_view_tokens(stmt_tokens) {
        True -> {
          let #(maybe_table, view_warnings) =
            parse_create_view_from_tokens(stmt_tokens, list.reverse(tables))
          let new_warnings = list.append(warnings, view_warnings)
          Ok(case maybe_table {
            Some(table) -> #([table, ..tables], current_enums, new_warnings)
            None -> #(tables, current_enums, new_warnings)
          })
        }
        False ->
          case is_alter_table_add_column_tokens(stmt_tokens) {
            True -> {
              use #(new_tables, added_enums) <- result.try(
                apply_alter_table_add_column(
                  path,
                  stmt_tokens,
                  current_enums,
                  tables,
                  engine,
                ),
              )
              Ok(#(
                new_tables,
                list.append(current_enums, added_enums),
                warnings,
              ))
            }
            False -> {
              use stmt_result <- result.try(parse_statement_tokens(
                path,
                stmt_tokens,
                current_enums,
                engine,
              ))
              case stmt_result {
                CreateTableResult(table:, new_enums:) ->
                  Ok(#(
                    [table, ..tables],
                    list.append(current_enums, new_enums),
                    warnings,
                  ))
                DDLApplied(action:) -> {
                  let #(new_tables, new_enums) =
                    apply_ddl_action(action, tables, current_enums, engine)
                  Ok(#(new_tables, new_enums, warnings))
                }
                Ignored -> Ok(#(tables, current_enums, warnings))
              }
            }
          }
      }
    })
    |> result.map(fn(triple) { #(list.reverse(triple.0), triple.1, triple.2) }),
  )

  Ok(ParsedSchema(tables:, enums: final_enums, warnings:))
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
      Ok(model.EnumDef(name:, values:, kind: model.PostgresEnum))
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
) -> #(Option(model.Table), List(SchemaWarning)) {
  case extract_view_name_result(tokens) {
    None -> #(None, [])
    Some(#(view_name, after_name)) -> {
      let after_as = skip_to_keyword(after_name, "as")
      case extract_after_select_result(after_as) {
        None -> #(None, [])
        Some(after_select) -> {
          let #(select_tokens, from_tokens) = split_at_from(after_select, 0, [])
          let source_tables =
            token_utils.extract_table_names([
              lexer.Keyword("from"),
              ..from_tokens
            ])

          let #(columns, warnings) = case select_tokens {
            [lexer.Star] -> #(
              list.flat_map(source_tables, fn(table_name) {
                case list.find(tables, fn(t) { t.name == table_name }) {
                  Ok(table) -> table.columns
                  Error(_) -> []
                }
              }),
              [],
            )
            _ -> resolve_view_columns(select_tokens, tables)
          }

          case columns {
            [] -> #(None, warnings)
            _ -> #(Some(model.Table(name: view_name, columns:)), warnings)
          }
        }
      }
    }
  }
}

fn extract_view_name_result(
  tokens: List(lexer.Token),
) -> Option(#(String, List(lexer.Token))) {
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
  case remaining {
    [lexer.Ident(n), ..rest] -> Some(#(string.lowercase(n), rest))
    [lexer.QuotedIdent(n), ..rest] -> Some(#(string.lowercase(n), rest))
    _ -> None
  }
}

fn extract_after_select_result(
  tokens: List(lexer.Token),
) -> Option(List(lexer.Token)) {
  case tokens {
    [lexer.Keyword("select"), ..rest] ->
      case rest {
        [] -> None
        _ -> Some(rest)
      }
    _ -> None
  }
}

fn resolve_view_columns(
  select_tokens: List(lexer.Token),
  tables: List(model.Table),
) -> #(List(model.Column), List(SchemaWarning)) {
  let view_cols = extract_view_columns(select_tokens)
  list.fold(view_cols, #([], []), fn(acc, view_col) {
    let #(columns, warnings) = acc
    let normalized = naming.normalize_identifier(view_col.name)
    case resolve_single_view_column(normalized, view_col.expr_tokens, tables) {
      Ok(col) -> #(list.append(columns, [col]), warnings)
      Error(warning) -> #(columns, list.append(warnings, [warning]))
    }
  })
}

fn resolve_single_view_column(
  name: String,
  expr_tokens: List(lexer.Token),
  tables: List(model.Table),
) -> Result(model.Column, SchemaWarning) {
  case find_column_in_tables(tables, name) {
    Some(col) -> Ok(model.Column(..col, name:))
    None ->
      case resolve_column_from_expr_tokens(expr_tokens, tables) {
        Some(col) -> Ok(model.Column(..col, name:))
        None ->
          case infer_view_expression_type(expr_tokens, tables) {
            Some(#(scalar_type, nullable)) ->
              Ok(model.Column(name:, scalar_type:, nullable:))
            None -> Error(UnresolvableViewColumn(column: name))
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
    // SQL syntax keywords
    [lexer.Keyword("cast"), lexer.LParen, ..rest] -> infer_cast_type(rest)

    // SQL function calls (now Ident tokens after #319)
    [lexer.Ident(fn_name), lexer.LParen, ..rest] -> {
      let lowered = string.lowercase(fn_name)
      case lowered {
        "count" -> Some(#(model.IntType, False))
        "avg" ->
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
        "sum" ->
          case extract_aggregate_inner_type(rest, tables) {
            Some(col) -> Some(#(col.scalar_type, True))
            None -> Some(#(model.FloatType, True))
          }
        "min" | "max" ->
          case extract_aggregate_inner_type(rest, tables) {
            Some(col) -> Some(#(col.scalar_type, True))
            None -> None
          }
        "coalesce" ->
          case extract_aggregate_inner_type(rest, tables) {
            Some(col) -> Some(#(col.scalar_type, False))
            None -> None
          }
        "row_number" | "rank" | "dense_rank" -> Some(#(model.IntType, False))
        _ -> None
      }
    }

    // Literals
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
///
/// Returns both the updated table list and any enum definitions synthesized
/// from inline MySQL `ENUM(...)` / `SET(...)` column types, so the caller can
/// thread them into the running catalog.
fn apply_alter_table_add_column(
  path: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  tables: List(model.Table),
  engine: model.Engine,
) -> Result(#(List(model.Table), List(model.EnumDef)), ParseError) {
  let #(table_name, col_tokens) = extract_alter_table_parts(tokens)

  case table_name {
    "" -> Ok(#(tables, []))
    _ -> {
      use maybe_col <- result.try(parse_column_tokens(
        path,
        table_name,
        col_tokens,
        enums,
        engine,
      ))
      case maybe_col {
        None -> Ok(#(tables, []))
        Some(#(col, new_enums)) ->
          Ok(#(
            list.map(tables, fn(t) {
              case t.name == table_name {
                True -> model.Table(..t, columns: list.append(t.columns, [col]))
                False -> t
              }
            }),
            new_enums,
          ))
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

type StatementResult {
  CreateTableResult(table: model.Table, new_enums: List(model.EnumDef))
  DDLApplied(action: DDLAction)
  Ignored
}

fn parse_statement_tokens(
  path: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(StatementResult, ParseError) {
  case is_create_table_tokens(tokens) {
    True -> {
      use maybe_table <- result.try(parse_create_table_tokens(
        path,
        tokens,
        enums,
        engine,
      ))
      case maybe_table {
        Some(#(table, new_enums)) -> Ok(CreateTableResult(table:, new_enums:))
        None -> Ok(Ignored)
      }
    }
    False ->
      case classify_unknown_statement(tokens, engine) {
        DestructiveDDL(action) -> Ok(DDLApplied(action:))
        SilentlyIgnored -> Ok(Ignored)
        UnsupportedMysql(detail:) -> Error(UnsupportedMysqlDdl(path:, detail:))
      }
  }
}

type UnknownStatementKind {
  DestructiveDDL(DDLAction)
  SilentlyIgnored
  /// Issue #419: surfaced when a MySQL schema file contains a DDL
  /// shape sqlode does not yet model. The detail is a short summary
  /// (the leading keywords) used directly in the user-facing error.
  UnsupportedMysql(detail: String)
}

type DDLAction {
  DropTable(table_name: String)
  DropView(view_name: String)
  DropType(type_name: String)
  AlterDropColumn(table_name: String, column_name: String)
  AlterRenameTable(old_name: String, new_name: String)
  AlterRenameColumn(table_name: String, old_name: String, new_name: String)
  AlterColumnType(
    table_name: String,
    column_name: String,
    type_tokens: List(lexer.Token),
  )
  /// MySQL `ALTER TABLE x MODIFY [COLUMN] <name> <type>`. The column
  /// keeps its name; both the type and the nullable flag are
  /// rewritten from the supplied tokens.
  AlterModifyColumn(
    table_name: String,
    column_name: String,
    type_tokens: List(lexer.Token),
    nullable: Bool,
  )
  /// MySQL `ALTER TABLE x CHANGE [COLUMN] <old> <new> <type>`. Renames
  /// the column and rewrites its type/nullable flag from the supplied
  /// tokens.
  AlterChangeColumn(
    table_name: String,
    old_name: String,
    new_name: String,
    type_tokens: List(lexer.Token),
    nullable: Bool,
  )
  AlterColumnSetNotNull(table_name: String, column_name: String)
  AlterColumnDropNotNull(table_name: String, column_name: String)
}

/// Classify a statement that is not a CREATE TABLE / VIEW / ENUM and not an
/// ALTER TABLE ... ADD COLUMN. The intent is to let informational or
/// out-of-scope DDL through silently (CREATE INDEX, COMMENT ON, transaction
/// control) while failing fast on DDL that materially changes the catalog
/// and would otherwise be missed (DROP TABLE, ALTER TABLE DROP/RENAME/ALTER).
///
/// The lexer reserves only a subset of SQL words as `Keyword` tokens. Words
/// like `rename`, `savepoint`, and `comment` arrive as `Ident` tokens, so
/// we normalise the first few tokens of the statement to lowercase strings
/// before matching, treating Keyword and Ident uniformly.
fn classify_unknown_statement(
  tokens: List(lexer.Token),
  engine: model.Engine,
) -> UnknownStatementKind {
  let words = tokens |> list.take(8) |> list.map(token_keyword_text)
  case words {
    ["create", "index", ..] -> SilentlyIgnored
    ["create", "unique", "index", ..] -> SilentlyIgnored
    ["drop", "index", ..] -> SilentlyIgnored
    ["comment", "on", ..] -> SilentlyIgnored
    ["begin", ..] -> SilentlyIgnored
    ["commit", ..] -> SilentlyIgnored
    ["rollback", ..] -> SilentlyIgnored
    ["savepoint", ..] -> SilentlyIgnored
    ["release", ..] -> SilentlyIgnored
    ["set", ..] -> SilentlyIgnored

    ["drop", "table", ..] -> parse_drop_table(tokens)
    ["drop", "view", ..] -> parse_drop_view(tokens)
    ["drop", "type", ..] -> parse_drop_type(tokens)

    ["alter", "table", ..] -> classify_alter_table_from_tokens(tokens)

    _ ->
      case engine {
        // Issue #419: MySQL schema files that contain DDL we do not
        // (yet) understand now surface an actionable error instead
        // of being silently dropped on the floor. PostgreSQL /
        // SQLite keep the legacy permissive behaviour — extending
        // the fail-fast policy to every engine is out of scope for
        // the MySQL completeness work.
        model.MySQL ->
          UnsupportedMysql(detail: summarise_unknown_mysql_statement(words))
        model.PostgreSQL | model.SQLite -> SilentlyIgnored
      }
  }
}

/// Parse DROP TABLE [IF EXISTS] <name> from the token list.
fn parse_drop_table(tokens: List(lexer.Token)) -> UnknownStatementKind {
  case tokens {
    [_, _, lexer.Keyword("if"), lexer.Keyword("exists"), name_tok, ..] ->
      DestructiveDDL(DropTable(table_name: extract_ident(name_tok)))
    [_, _, name_tok, ..] ->
      DestructiveDDL(DropTable(table_name: extract_ident(name_tok)))
    _ -> SilentlyIgnored
  }
}

/// Parse DROP VIEW [IF EXISTS] <name> from the token list.
fn parse_drop_view(tokens: List(lexer.Token)) -> UnknownStatementKind {
  case tokens {
    [_, _, lexer.Keyword("if"), lexer.Keyword("exists"), name_tok, ..] ->
      DestructiveDDL(DropView(view_name: extract_ident(name_tok)))
    [_, _, name_tok, ..] ->
      DestructiveDDL(DropView(view_name: extract_ident(name_tok)))
    _ -> SilentlyIgnored
  }
}

/// Parse DROP TYPE [IF EXISTS] <name> from the token list.
fn parse_drop_type(tokens: List(lexer.Token)) -> UnknownStatementKind {
  case tokens {
    [_, _, lexer.Keyword("if"), lexer.Keyword("exists"), name_tok, ..] ->
      DestructiveDDL(DropType(type_name: extract_ident(name_tok)))
    [_, _, name_tok, ..] ->
      DestructiveDDL(DropType(type_name: extract_ident(name_tok)))
    _ -> SilentlyIgnored
  }
}

/// Classify ALTER TABLE statements from the full token list.
fn classify_alter_table_from_tokens(
  tokens: List(lexer.Token),
) -> UnknownStatementKind {
  // ALTER TABLE [IF EXISTS] [ONLY] <name> <action>
  let after_alter_table = case tokens {
    [_, _, ..rest] -> rest
    _ -> []
  }
  let #(after_modifiers, _) = skip_alter_modifiers(after_alter_table)
  case after_modifiers {
    [name_tok, ..rest] -> {
      let table_name = extract_ident(name_tok)
      classify_alter_action_tokens(table_name, rest)
    }
    [] -> SilentlyIgnored
  }
}

fn skip_alter_modifiers(tokens: List(lexer.Token)) -> #(List(lexer.Token), Bool) {
  case tokens {
    [lexer.Keyword("if"), lexer.Keyword("exists"), ..rest] ->
      skip_alter_modifiers(rest)
    [lexer.Keyword("only"), ..rest] -> skip_alter_modifiers(rest)
    _ -> #(tokens, False)
  }
}

fn classify_alter_action_tokens(
  table_name: String,
  tokens: List(lexer.Token),
) -> UnknownStatementKind {
  let words = tokens |> list.take(8) |> list.map(token_keyword_text)
  case words {
    ["drop", "constraint", ..] -> SilentlyIgnored
    ["drop", "column", "if", "exists", col_name, ..] ->
      DestructiveDDL(AlterDropColumn(table_name:, column_name: col_name))
    ["drop", "column", col_name, ..] ->
      DestructiveDDL(AlterDropColumn(table_name:, column_name: col_name))
    ["drop", col_name, ..] ->
      DestructiveDDL(AlterDropColumn(table_name:, column_name: col_name))
    ["rename", "to", new_name, ..] ->
      DestructiveDDL(AlterRenameTable(old_name: table_name, new_name:))
    ["rename", "column", old_name, "to", new_name, ..] ->
      DestructiveDDL(AlterRenameColumn(table_name:, old_name:, new_name:))
    ["rename", old_name, "to", new_name, ..] ->
      DestructiveDDL(AlterRenameColumn(table_name:, old_name:, new_name:))
    ["alter", "column", _col_name, "set", "not", "null", ..] ->
      DestructiveDDL(AlterColumnSetNotNull(
        table_name:,
        column_name: extract_alter_column_name(tokens),
      ))
    ["alter", "column", _col_name, "drop", "not", "null", ..] ->
      DestructiveDDL(AlterColumnDropNotNull(
        table_name:,
        column_name: extract_alter_column_name(tokens),
      ))
    ["alter", "column", _col_name, "type", ..]
    | ["alter", "column", _col_name, "set", "data", "type", ..] ->
      DestructiveDDL(AlterColumnType(
        table_name:,
        column_name: extract_alter_column_name(tokens),
        type_tokens: extract_alter_type_tokens(tokens),
      ))
    // MySQL: MODIFY [COLUMN] <name> <type> [constraints...]
    ["modify", "column", ..] -> classify_mysql_modify(table_name, tokens)
    ["modify", _, ..] -> classify_mysql_modify(table_name, tokens)
    // MySQL: CHANGE [COLUMN] <old> <new> <type> [constraints...]
    ["change", "column", ..] -> classify_mysql_change(table_name, tokens)
    ["change", _, _, ..] -> classify_mysql_change(table_name, tokens)
    ["add", "constraint", ..] -> SilentlyIgnored
    ["add", "primary", ..] -> SilentlyIgnored
    ["add", "unique", ..] -> SilentlyIgnored
    ["add", "foreign", ..] -> SilentlyIgnored
    ["add", "check", ..] -> SilentlyIgnored
    ["add", "index", ..] -> SilentlyIgnored
    _ -> SilentlyIgnored
  }
}

/// Parse `MODIFY [COLUMN] <name> <type-and-constraints>` into an
/// `AlterModifyColumn` action. The type tokens are everything between
/// the column name and the next column-constraint keyword; the
/// nullability is derived from a `NOT NULL` presence check on the
/// remaining tokens (MySQL columns default to nullable).
fn classify_mysql_modify(
  table_name: String,
  tokens: List(lexer.Token),
) -> UnknownStatementKind {
  let after_modify = case tokens {
    [_, lexer.Keyword("column"), ..rest] -> rest
    [_, ..rest] -> rest
    _ -> []
  }
  case after_modify {
    [name_tok, ..rest] -> {
      let column_name = extract_ident(name_tok)
      let type_tokens = take_type_tokens_from_lexer(rest, [])
      let nullable = !tokens_contain_not_null(rest)
      DestructiveDDL(AlterModifyColumn(
        table_name:,
        column_name:,
        type_tokens:,
        nullable:,
      ))
    }
    [] -> SilentlyIgnored
  }
}

/// Parse `CHANGE [COLUMN] <old> <new> <type-and-constraints>` into an
/// `AlterChangeColumn` action — MySQL's combined rename + retype.
fn classify_mysql_change(
  table_name: String,
  tokens: List(lexer.Token),
) -> UnknownStatementKind {
  let after_change = case tokens {
    [_, lexer.Keyword("column"), ..rest] -> rest
    [_, ..rest] -> rest
    _ -> []
  }
  case after_change {
    [old_tok, new_tok, ..rest] -> {
      let old_name = extract_ident(old_tok)
      let new_name = extract_ident(new_tok)
      let type_tokens = take_type_tokens_from_lexer(rest, [])
      let nullable = !tokens_contain_not_null(rest)
      DestructiveDDL(AlterChangeColumn(
        table_name:,
        old_name:,
        new_name:,
        type_tokens:,
        nullable:,
      ))
    }
    _ -> SilentlyIgnored
  }
}

/// Extract the column name from ALTER [COLUMN] <name> ... tokens.
fn extract_alter_column_name(tokens: List(lexer.Token)) -> String {
  case tokens {
    [_, lexer.Keyword("column"), name_tok, ..] -> extract_ident(name_tok)
    [_, name_tok, ..] -> extract_ident(name_tok)
    _ -> ""
  }
}

/// Extract TYPE tokens from ALTER [COLUMN] <name> [SET DATA] TYPE <tokens>.
fn extract_alter_type_tokens(tokens: List(lexer.Token)) -> List(lexer.Token) {
  case tokens {
    [] -> []
    [lexer.Keyword("type"), ..rest] -> rest
    [_, ..rest] -> extract_alter_type_tokens(rest)
  }
}

/// Apply a destructive DDL action to the tables and enums lists. The
/// engine parameter is threaded through so MySQL `ALTER TABLE ...
/// MODIFY/CHANGE COLUMN <type>` can resolve modifier-aware types
/// (TINYINT(1), DECIMAL, UNSIGNED, ENUM/SET) using the same
/// classification rules as CREATE TABLE.
fn apply_ddl_action(
  action: DDLAction,
  tables: List(model.Table),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> #(List(model.Table), List(model.EnumDef)) {
  case action {
    DropTable(table_name:) -> #(
      list.filter(tables, fn(t) {
        string.lowercase(t.name) != string.lowercase(table_name)
      }),
      enums,
    )
    DropView(view_name:) -> #(
      list.filter(tables, fn(t) {
        string.lowercase(t.name) != string.lowercase(view_name)
      }),
      enums,
    )
    DropType(type_name:) -> #(
      tables,
      list.filter(enums, fn(e) {
        string.lowercase(e.name) != string.lowercase(type_name)
      }),
    )
    AlterDropColumn(table_name:, column_name:) -> #(
      list.map(tables, fn(t) {
        case string.lowercase(t.name) == string.lowercase(table_name) {
          True ->
            model.Table(
              ..t,
              columns: list.filter(t.columns, fn(c) {
                string.lowercase(c.name) != string.lowercase(column_name)
              }),
            )
          False -> t
        }
      }),
      enums,
    )
    AlterRenameTable(old_name:, new_name:) -> #(
      list.map(tables, fn(t) {
        case string.lowercase(t.name) == string.lowercase(old_name) {
          True -> model.Table(..t, name: string.lowercase(new_name))
          False -> t
        }
      }),
      enums,
    )
    AlterRenameColumn(table_name:, old_name:, new_name:) -> #(
      list.map(tables, fn(t) {
        case string.lowercase(t.name) == string.lowercase(table_name) {
          True ->
            model.Table(
              ..t,
              columns: list.map(t.columns, fn(c) {
                case string.lowercase(c.name) == string.lowercase(old_name) {
                  True -> model.Column(..c, name: string.lowercase(new_name))
                  False -> c
                }
              }),
            )
          False -> t
        }
      }),
      enums,
    )
    AlterColumnType(table_name:, column_name:, type_tokens:) -> {
      let type_text = render_type_tokens(type_tokens)
      let new_type = case model.parse_sql_type_for_engine(type_text, engine) {
        Ok(t) -> Some(t)
        Error(_) -> None
      }
      case new_type {
        Some(scalar_type) -> #(
          rewrite_column(tables, table_name, column_name, fn(c) {
            model.Column(..c, scalar_type:)
          }),
          enums,
        )
        None -> #(tables, enums)
      }
    }
    AlterModifyColumn(table_name:, column_name:, type_tokens:, nullable:) -> {
      let #(scalar_type, new_enums) =
        resolve_mysql_alter_type(
          type_tokens,
          table_name,
          column_name,
          enums,
          engine,
        )
      let updated_tables =
        rewrite_column(tables, table_name, column_name, fn(c) {
          model.Column(..c, scalar_type:, nullable:)
        })
      #(updated_tables, new_enums)
    }
    AlterChangeColumn(
      table_name:,
      old_name:,
      new_name:,
      type_tokens:,
      nullable:,
    ) -> {
      let #(scalar_type, new_enums) =
        resolve_mysql_alter_type(
          type_tokens,
          table_name,
          new_name,
          enums,
          engine,
        )
      let updated_tables =
        rewrite_column(tables, table_name, old_name, fn(_) {
          model.Column(
            name: string.lowercase(new_name),
            scalar_type:,
            nullable:,
          )
        })
      #(updated_tables, new_enums)
    }
    AlterColumnSetNotNull(table_name:, column_name:) -> #(
      list.map(tables, fn(t) {
        case string.lowercase(t.name) == string.lowercase(table_name) {
          True ->
            model.Table(
              ..t,
              columns: list.map(t.columns, fn(c) {
                case string.lowercase(c.name) == string.lowercase(column_name) {
                  True -> model.Column(..c, nullable: False)
                  False -> c
                }
              }),
            )
          False -> t
        }
      }),
      enums,
    )
    AlterColumnDropNotNull(table_name:, column_name:) -> #(
      list.map(tables, fn(t) {
        case string.lowercase(t.name) == string.lowercase(table_name) {
          True ->
            model.Table(
              ..t,
              columns: list.map(t.columns, fn(c) {
                case string.lowercase(c.name) == string.lowercase(column_name) {
                  True -> model.Column(..c, nullable: True)
                  False -> c
                }
              }),
            )
          False -> t
        }
      }),
      enums,
    )
  }
}

/// Render the leading words of a statement back into a short summary
/// suitable for the user-facing `UnsupportedMysqlDdl` detail. We only
/// take the first three non-empty words so a `RENAME TABLE a TO b ...`
/// reads as `RENAME TABLE a` rather than the entire token stream.
fn summarise_unknown_mysql_statement(words: List(String)) -> String {
  let summary =
    words
    |> list.filter(fn(word) { word != "" })
    |> list.take(3)
    |> list.map(string.uppercase)
    |> string.join(" ")
  case summary {
    "" -> "(empty statement)"
    _ ->
      summary
      <> " ... — sqlode does not (yet) understand this statement; file"
      <> " an issue or pre-process the schema to remove it."
  }
}

fn token_keyword_text(token: lexer.Token) -> String {
  case token {
    lexer.Keyword(k) -> k
    lexer.Ident(i) -> string.lowercase(i)
    lexer.QuotedIdent(i) -> string.lowercase(i)
    _ -> ""
  }
}

/// Apply `update` to the column named `column_name` inside `table_name`,
/// leaving all other columns and tables untouched. Used by every ALTER
/// path that rewrites a single column in place so the per-action code
/// does not repeat the table/column-walking boilerplate.
fn rewrite_column(
  tables: List(model.Table),
  table_name: String,
  column_name: String,
  update: fn(model.Column) -> model.Column,
) -> List(model.Table) {
  list.map(tables, fn(t) {
    case string.lowercase(t.name) == string.lowercase(table_name) {
      True ->
        model.Table(
          ..t,
          columns: list.map(t.columns, fn(c) {
            case string.lowercase(c.name) == string.lowercase(column_name) {
              True -> update(c)
              False -> c
            }
          }),
        )
      False -> t
    }
  })
}

/// Resolve the new column type for a MySQL ALTER MODIFY/CHANGE: the
/// type tokens may contain an inline `ENUM(...)` / `SET(...)`, in
/// which case we synthesize a fresh `EnumDef` (named after the target
/// column) and return it for the caller to append to the catalog.
/// Otherwise we fall back to the engine-aware classifier; an
/// unrecognised type leaves the existing column type unchanged
/// (`StringType` is *not* used as a silent fallback).
fn resolve_mysql_alter_type(
  type_tokens: List(lexer.Token),
  table_name: String,
  column_name: String,
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> #(model.ScalarType, List(model.EnumDef)) {
  case
    detect_mysql_inline_enum_set(type_tokens, table_name, column_name, engine)
  {
    Some(InlineEnum(scalar_type:, new_enum:)) -> #(
      scalar_type,
      list.append(enums, [new_enum]),
    )
    None -> {
      let type_text = render_type_tokens(type_tokens)
      let resolved = case find_enum(type_text, enums) {
        Some(enum_name) -> Ok(model.EnumType(enum_name))
        None -> model.parse_sql_type_for_engine(type_text, engine)
      }
      case resolved {
        Ok(t) -> #(t, enums)
        Error(_) -> #(model.StringType, enums)
      }
    }
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
  path: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(Option(#(model.Table, List(model.EnumDef))), ParseError) {
  // Find the table name: last Ident/QuotedIdent before the first LParen
  let #(header, body) = split_at_lparen(tokens, [])

  case body {
    [] ->
      Error(InvalidCreateTable(
        path:,
        detail: "missing opening parenthesis in CREATE TABLE statement",
      ))
    _ -> {
      use table_name <- result.try(
        find_last_ident(header)
        |> result.map_error(fn(_) {
          InvalidCreateTable(path:, detail: "missing table name")
        }),
      )

      // Strip trailing RParen from body
      let body_tokens = strip_trailing_rparen(body)

      use #(columns, new_enums) <- result.try(parse_columns_tokens(
        path,
        table_name,
        body_tokens,
        enums,
        engine,
      ))
      Ok(Some(#(model.Table(name: table_name, columns:), new_enums)))
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
  path: String,
  table_name: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(#(List(model.Column), List(model.EnumDef)), ParseError) {
  split_tokens_by_comma(tokens)
  |> list.try_fold(#([], []), fn(acc, col_tokens) {
    let #(columns, collected_enums) = acc
    // Each column sees all enums known so far (including ones synthesized
    // from earlier inline MySQL ENUM(...) columns in the same table), so a
    // later column referencing the synthesized name could in theory resolve
    // it. This is symmetrical to how top-level CREATE TYPE enums are
    // threaded through the fold in parse_content.
    let visible_enums = list.append(enums, collected_enums)
    use maybe_column <- result.try(parse_column_tokens(
      path,
      table_name,
      col_tokens,
      visible_enums,
      engine,
    ))
    case maybe_column {
      Some(#(column, new_enums)) ->
        Ok(#([column, ..columns], list.append(collected_enums, new_enums)))
      None -> Ok(acc)
    }
  })
  |> result.map(fn(pair) { #(list.reverse(pair.0), pair.1) })
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

fn parse_named_column(
  path: String,
  table_name: String,
  raw_name: String,
  all_tokens: List(lexer.Token),
  rest: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(Option(#(model.Column, List(model.EnumDef))), ParseError) {
  let name = naming.normalize_identifier(raw_name)
  let type_toks = take_type_tokens_from_lexer(rest, [])
  case type_toks {
    [] ->
      Error(InvalidColumn(
        path: path,
        table: table_name,
        detail: "missing type for column " <> name,
      ))
    _ ->
      build_column_from_type_tokens(
        path,
        table_name,
        name,
        all_tokens,
        type_toks,
        enums,
        engine,
      )
  }
}

fn parse_column_tokens(
  path: String,
  table_name: String,
  tokens: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(Option(#(model.Column, List(model.EnumDef))), ParseError) {
  case tokens {
    [] -> Ok(None)
    [first, ..rest] ->
      case first {
        lexer.Keyword("primary")
        | lexer.Keyword("foreign")
        | lexer.Keyword("unique")
        | lexer.Keyword("constraint")
        | lexer.Keyword("check") -> Ok(None)
        // Non-reserved SQL keywords like `action`, `name`, `order`
        // are frequently used as column identifiers in user schemas.
        // Accept them here the same way Ident/QuotedIdent are handled.
        lexer.Keyword(n) ->
          parse_named_column(path, table_name, n, tokens, rest, enums, engine)
        lexer.Ident(n) | lexer.QuotedIdent(n) -> {
          let name = naming.normalize_identifier(n)
          let type_toks = take_type_tokens_from_lexer(rest, [])

          case type_toks {
            [] ->
              Error(InvalidColumn(
                path:,
                table: table_name,
                detail: "missing type for column " <> name,
              ))
            _ ->
              build_column_from_type_tokens(
                path,
                table_name,
                name,
                tokens,
                type_toks,
                enums,
                engine,
              )
          }
        }
        _ -> Ok(None)
      }
  }
}

/// Shared logic for `parse_named_column` and `parse_column_tokens`.
/// Inspects the column's type tokens, detects MySQL inline `ENUM(...)`
/// or `SET(...)` when `engine == MySQL`, synthesizes enum definitions,
/// and falls through to the shared lookup / `parse_sql_type` pipeline
/// otherwise.
fn build_column_from_type_tokens(
  path: String,
  table_name: String,
  name: String,
  all_tokens: List(lexer.Token),
  type_toks: List(lexer.Token),
  enums: List(model.EnumDef),
  engine: model.Engine,
) -> Result(Option(#(model.Column, List(model.EnumDef))), ParseError) {
  let type_text = render_type_tokens(type_toks)
  let nullable = case
    tokens_contain_not_null(all_tokens)
    || tokens_contain_keyword(all_tokens, "primary")
    || string.contains(type_text, "serial")
  {
    True -> False
    False -> True
  }

  case detect_mysql_inline_enum_set(type_toks, table_name, name, engine) {
    Some(InlineEnum(scalar_type:, new_enum:)) ->
      Ok(Some(#(model.Column(name:, scalar_type:, nullable:), [new_enum])))
    None -> {
      use scalar_type <- result.try(case find_enum(type_text, enums) {
        Some(enum_name) -> Ok(model.EnumType(enum_name))
        None ->
          infer_scalar_type_for_engine(type_text, engine)
          |> result.map_error(fn(detail) {
            InvalidColumn(path:, table: table_name, detail:)
          })
      })
      Ok(Some(#(model.Column(name:, scalar_type:, nullable:), [])))
    }
  }
}

type InlineEnumDetection {
  InlineEnum(scalar_type: model.ScalarType, new_enum: model.EnumDef)
}

/// Detect MySQL inline `ENUM(...)` / `SET(...)` on a column's type
/// tokens. Gated by `engine == MySQL` so PostgreSQL/SQLite schemas —
/// where `enum` / `set` could conceivably appear as a non-type keyword
/// elsewhere — keep their existing behavior.
///
/// The name synthesis rule is `<lowercased_table>_<column>`, which
/// lets two tables carry columns with overlapping value sets without
/// colliding. For SET the column resolves to `StringType` (the
/// documented fallback per Issue #407) but the values are still
/// preserved in the catalog for future native SET support.
fn detect_mysql_inline_enum_set(
  type_toks: List(lexer.Token),
  table_name: String,
  column_name: String,
  engine: model.Engine,
) -> Option(InlineEnumDetection) {
  case engine {
    model.MySQL ->
      case type_toks {
        [lexer.Keyword("enum"), lexer.LParen, ..rest] -> {
          let values = extract_enum_values(rest, [])
          let synthetic = synthetic_enum_name(table_name, column_name)
          Some(InlineEnum(
            scalar_type: model.EnumType(synthetic),
            new_enum: model.EnumDef(
              name: synthetic,
              values:,
              kind: model.MySqlEnum,
            ),
          ))
        }
        [lexer.Keyword("set"), lexer.LParen, ..rest] -> {
          let values = extract_enum_values(rest, [])
          let synthetic = synthetic_enum_name(table_name, column_name)
          Some(InlineEnum(
            scalar_type: model.SetType(synthetic),
            new_enum: model.EnumDef(
              name: synthetic,
              values:,
              kind: model.MySqlSet,
            ),
          ))
        }
        _ -> None
      }
    _ -> None
  }
}

fn synthetic_enum_name(table_name: String, column_name: String) -> String {
  string.lowercase(table_name) <> "_" <> string.lowercase(column_name)
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
    [lexer.Ident(name), ..rest] ->
      case is_column_constraint(string.lowercase(name)) {
        True -> list.reverse(acc)
        False -> take_type_tokens_from_lexer(rest, [lexer.Ident(name), ..acc])
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
      let token_text = case tok {
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
      case token_text {
        "" -> render_type_tokens_loop(rest, acc)
        _ -> render_type_tokens_loop(rest, [token_text, ..acc])
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

fn infer_scalar_type_for_engine(
  type_text: String,
  engine: model.Engine,
) -> Result(model.ScalarType, String) {
  model.parse_sql_type_for_engine(type_text, engine)
  |> result.replace_error(
    "unrecognized SQL type \""
    <> type_text
    <> "\". Supported types: int, serial, float, numeric, decimal, bool, text,"
    <> " char, bytea, uuid, json, jsonb, timestamp, datetime, date, time,"
    <> " interval. Hint: add a type override in sqlode.yaml under"
    <> " overrides.db_type",
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
      // MySQL noise that appears after the type and must end type
      // collection so `BIGINT AUTO_INCREMENT` does not bleed
      // `auto_increment` into the type text and so
      // `DATETIME ON UPDATE CURRENT_TIMESTAMP` resolves cleanly.
      "auto_increment",
      "on",
      "character",
      "comment",
      "invisible",
      "visible",
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
    InvalidCreateTable(path:, detail:) ->
      path_prefix(path) <> "Invalid CREATE TABLE statement: " <> detail
    InvalidColumn(path:, table:, detail:) ->
      path_prefix(path)
      <> "Invalid column definition in table "
      <> table
      <> ": "
      <> detail
    UnsupportedMysqlDdl(path:, detail:) ->
      path_prefix(path) <> "Unsupported MySQL DDL statement: " <> detail
  }
}

fn path_prefix(path: String) -> String {
  case path {
    "" -> ""
    _ -> path <> ": "
  }
}

pub fn warning_to_string(warning: SchemaWarning) -> String {
  let UnresolvableViewColumn(column:) = warning
  "Warning: view column \""
  <> column
  <> "\" could not be resolved from source tables — skipping column."
}
