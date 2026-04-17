import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/runtime

pub type ParseError {
  InvalidAnnotation(path: String, line: Int, detail: String)
  MissingSql(path: String, line: Int, name: String)
}

type PendingQuery {
  PendingQuery(
    name: String,
    function_name: String,
    command: runtime.QueryCommand,
    start_line: Int,
    body_rev: List(String),
  )
}

pub fn parse_file(
  path: String,
  engine: model.Engine,
  naming_ctx: naming.NamingContext,
  content: String,
) -> Result(List(model.ParsedQuery), ParseError) {
  parse_lines(
    naming_ctx,
    string.split(content, "\n"),
    path,
    engine,
    1,
    None,
    [],
    False,
  )
  |> result.map(list.reverse)
}

fn parse_lines(
  naming_ctx: naming.NamingContext,
  lines: List(String),
  path: String,
  engine: model.Engine,
  line_number: Int,
  pending: Option(PendingQuery),
  parsed_rev: List(model.ParsedQuery),
  skip_next: Bool,
) -> Result(List(model.ParsedQuery), ParseError) {
  case lines {
    [] -> finalize_pending(naming_ctx, pending, path, engine, parsed_rev)
    [line, ..rest] -> {
      let trimmed = string.trim(line)

      case is_skip_annotation(trimmed) {
        True -> {
          use parsed_rev <- result.try(finalize_pending(
            naming_ctx,
            pending,
            path,
            engine,
            parsed_rev,
          ))
          parse_lines(
            naming_ctx,
            rest,
            path,
            engine,
            line_number + 1,
            None,
            parsed_rev,
            True,
          )
        }
        False ->
          case parse_annotation(naming_ctx, trimmed, path, line_number) {
            Ok(Some(next_pending)) -> {
              use parsed_rev <- result.try(finalize_pending(
                naming_ctx,
                pending,
                path,
                engine,
                parsed_rev,
              ))

              case skip_next {
                True ->
                  parse_lines(
                    naming_ctx,
                    rest,
                    path,
                    engine,
                    line_number + 1,
                    None,
                    parsed_rev,
                    False,
                  )
                False ->
                  parse_lines(
                    naming_ctx,
                    rest,
                    path,
                    engine,
                    line_number + 1,
                    Some(next_pending),
                    parsed_rev,
                    False,
                  )
              }
            }
            Ok(None) -> {
              let pending = case pending {
                Some(PendingQuery(
                  name:,
                  function_name:,
                  command:,
                  start_line:,
                  body_rev:,
                )) ->
                  Some(
                    PendingQuery(
                      name:,
                      function_name:,
                      command:,
                      start_line:,
                      body_rev: [line, ..body_rev],
                    ),
                  )
                None -> None
              }

              parse_lines(
                naming_ctx,
                rest,
                path,
                engine,
                line_number + 1,
                pending,
                parsed_rev,
                skip_next,
              )
            }
            Error(error) -> Error(error)
          }
      }
    }
  }
}

fn finalize_pending(
  _naming_ctx: naming.NamingContext,
  pending: Option(PendingQuery),
  path: String,
  engine: model.Engine,
  parsed_rev: List(model.ParsedQuery),
) -> Result(List(model.ParsedQuery), ParseError) {
  case pending {
    None -> Ok(parsed_rev)
    Some(PendingQuery(name:, function_name:, command:, start_line:, body_rev:)) -> {
      let sql =
        body_rev
        |> list.reverse
        |> string.join("\n")
        |> string.trim

      case sql == "" {
        True -> Error(MissingSql(path:, line: start_line, name:))
        False -> {
          // Phase 1: Tokenize the raw SQL
          let tokens = lexer.tokenize(sql, engine)

          // Phase 2: Expand @name shorthands in token list (non-MySQL)
          let #(tokens, at_macros, next_idx) =
            expand_at_name_tokens(engine, tokens, 1)

          // Phase 3: Expand sqlode.arg/narg/slice(...) macros in token list
          let #(tokens, expanded_macros) =
            expand_macro_tokens(engine, tokens, next_idx)

          let macros = list.append(at_macros, expanded_macros)

          // Phase 4: Render expanded token list back to SQL
          let expanded_sql =
            lexer.tokens_to_string(
              tokens,
              lexer.TokenRenderOptions(
                uppercase_keywords: False,
                preserve_quotes: True,
                engine: Some(engine),
              ),
            )

          // Phase 5: Count parameters from the already-expanded token list
          let param_count = count_parameters_from_tokens(engine, tokens)

          Ok([
            model.ParsedQuery(
              name:,
              function_name:,
              command:,
              sql: expanded_sql,
              source_path: path,
              param_count:,
              macros:,
            ),
            ..parsed_rev
          ])
        }
      }
    }
  }
}

fn parse_annotation(
  naming_ctx: naming.NamingContext,
  line: String,
  path: String,
  line_number: Int,
) -> Result(Option(PendingQuery), ParseError) {
  case extract_annotation_payload(line) {
    None -> Ok(None)
    Some(rest) -> {
      let parts =
        string.split(rest, " ")
        |> list.map(string.trim)
        |> list.filter(fn(part) { part != "" })

      case parts {
        [name, command_text] -> {
          use command <- result.try(
            model.parse_query_command(command_text)
            |> result.map_error(fn(detail) {
              InvalidAnnotation(path:, line: line_number, detail:)
            }),
          )

          Ok(
            Some(
              PendingQuery(
                name:,
                function_name: naming.to_snake_case(naming_ctx, name),
                command:,
                start_line: line_number,
                body_rev: [],
              ),
            ),
          )
        }
        _ ->
          Error(InvalidAnnotation(
            path:,
            line: line_number,
            detail: "expected '-- name: <Name> <command>' or '/* name: <Name> <command> */' where command is one of: :one, :many, :exec, :execresult, :execrows, :execlastid, :batchone, :batchmany, :batchexec, :copyfrom",
          ))
      }
    }
  }
}

/// Extracts the annotation payload (the text after `name:` and before any
/// terminator) from a trimmed line. Supports both `-- name: ...` and
/// `/* name: ... */` forms. Returns None for non-annotation lines so callers
/// can treat them as SQL body.
fn extract_annotation_payload(line: String) -> Option(String) {
  case extract_line_annotation(line) {
    Some(payload) -> Some(payload)
    None -> extract_block_annotation(line)
  }
}

fn extract_line_annotation(line: String) -> Option(String) {
  case string.starts_with(line, "-- name:") {
    False -> None
    True ->
      line
      |> string.replace("-- name:", "")
      |> string.trim
      |> Some
  }
}

fn extract_block_annotation(line: String) -> Option(String) {
  case string.starts_with(line, "/*") && string.ends_with(line, "*/") {
    False -> None
    True -> {
      let inner =
        line
        |> string.drop_start(2)
        |> string.drop_end(2)

      case string.contains(inner, "*/") {
        True -> None
        False -> {
          let inner_trimmed = string.trim(inner)
          case string.starts_with(inner_trimmed, "name:") {
            False -> None
            True ->
              inner_trimmed
              |> string.replace("name:", "")
              |> string.trim
              |> Some
          }
        }
      }
    }
  }
}

fn is_skip_annotation(line: String) -> Bool {
  line == "-- sqlode:skip"
}

/// Count parameters from an already-expanded token list.
fn count_parameters_from_tokens(
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Int {
  let placeholders =
    tokens
    |> list.filter_map(fn(token) {
      case token {
        lexer.Placeholder(p) -> Ok(p)
        _ -> Error(Nil)
      }
    })

  case engine {
    model.PostgreSQL ->
      placeholders
      |> list.filter_map(fn(p) { string.replace(p, "$", "") |> int.parse })
      |> list.fold(0, fn(max_idx, v) {
        case v > max_idx {
          True -> v
          False -> max_idx
        }
      })
    model.MySQL -> list.length(placeholders)
    model.SQLite -> {
      let #(anon, named) = list.partition(placeholders, fn(p) { p == "?" })
      list.length(anon) + list.length(list.unique(named))
    }
  }
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    InvalidAnnotation(path:, line:, detail:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": invalid query annotation: "
      <> detail
    MissingSql(path:, line:, name:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": query "
      <> name
      <> " is missing SQL body"
  }
}

// ============================================================
// Token-based @name expansion
// ============================================================

/// Expand @name shorthands in the token list.
/// For non-MySQL engines, Placeholder("@name") tokens are replaced
/// with engine-appropriate placeholders ($N, ?N).
/// The lexer only emits Placeholder("@...") when @ is followed by
/// alpha/underscore, so @1 is never matched (it becomes Operator+NumberLit).
fn expand_at_name_tokens(
  engine: model.Engine,
  tokens: List(lexer.Token),
  start_idx: Int,
) -> #(List(lexer.Token), List(model.Macro), Int) {
  case engine {
    model.MySQL -> #(tokens, [], start_idx)
    _ -> expand_at_loop(engine, tokens, start_idx, dict.new(), [], [])
  }
}

fn expand_at_loop(
  engine: model.Engine,
  tokens: List(lexer.Token),
  idx: Int,
  seen: dict.Dict(String, Int),
  token_acc: List(lexer.Token),
  macro_acc: List(model.Macro),
) -> #(List(lexer.Token), List(model.Macro), Int) {
  case tokens {
    [] -> #(list.reverse(token_acc), list.reverse(macro_acc), idx)
    [lexer.Placeholder(p), ..rest] ->
      case string.starts_with(p, "@") {
        True -> {
          let name = string.drop_start(p, 1)
          case engine, dict.get(seen, name) {
            model.SQLite, Ok(existing_idx) -> {
              let placeholder = engine_placeholder(engine, existing_idx)
              expand_at_loop(
                engine,
                rest,
                idx,
                seen,
                [lexer.Placeholder(placeholder), ..token_acc],
                macro_acc,
              )
            }
            _, _ -> {
              let placeholder = engine_placeholder(engine, idx)
              let new_seen = case engine {
                model.SQLite -> dict.insert(seen, name, idx)
                _ -> seen
              }
              expand_at_loop(
                engine,
                rest,
                idx + 1,
                new_seen,
                [lexer.Placeholder(placeholder), ..token_acc],
                [model.MacroArg(index: idx, name:), ..macro_acc],
              )
            }
          }
        }
        False ->
          expand_at_loop(
            engine,
            rest,
            idx,
            seen,
            [lexer.Placeholder(p), ..token_acc],
            macro_acc,
          )
      }
    [token, ..rest] ->
      expand_at_loop(engine, rest, idx, seen, [token, ..token_acc], macro_acc)
  }
}

// ============================================================
// Token-based sqlode.arg/narg/slice expansion
// ============================================================

/// Expand sqlode.arg(name), sqlode.narg(name), sqlode.slice(name) macros
/// by walking the token list and replacing the token span with a Placeholder.
/// Pattern: Ident("sqlode") Dot Ident("arg"|"narg"|"slice") LParen ...arg... RParen
fn expand_macro_tokens(
  engine: model.Engine,
  tokens: List(lexer.Token),
  start_idx: Int,
) -> #(List(lexer.Token), List(model.Macro)) {
  expand_macro_loop(engine, tokens, start_idx, [], [])
}

fn expand_macro_loop(
  engine: model.Engine,
  tokens: List(lexer.Token),
  idx: Int,
  token_acc: List(lexer.Token),
  macro_acc: List(model.Macro),
) -> #(List(lexer.Token), List(model.Macro)) {
  case tokens {
    [] -> #(list.reverse(token_acc), list.reverse(macro_acc))

    // Match: sqlode.arg|narg|slice(...)
    [lexer.Ident(mod), lexer.Dot, lexer.Ident(kind), lexer.LParen, ..rest]
      if { mod == "sqlode" || mod == "Sqlode" || mod == "SQLODE" }
      && { kind == "arg" || kind == "narg" || kind == "slice" }
    -> {
      // Collect tokens inside parens to extract the argument name
      let #(arg_tokens, remaining) = collect_macro_arg_tokens(rest, 1, [])
      let name = extract_arg_name(arg_tokens)
      let placeholder = engine_placeholder(engine, idx)
      let macro_entry = case kind {
        "narg" -> model.MacroNarg(index: idx, name:)
        "slice" -> model.MacroSlice(index: idx, name:)
        _ -> model.MacroArg(index: idx, name:)
      }
      expand_macro_loop(
        engine,
        remaining,
        idx + 1,
        [lexer.Placeholder(placeholder), ..token_acc],
        [macro_entry, ..macro_acc],
      )
    }

    [token, ..rest] ->
      expand_macro_loop(engine, rest, idx, [token, ..token_acc], macro_acc)
  }
}

/// Collect tokens inside macro parens until the matching RParen.
fn collect_macro_arg_tokens(
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
          collect_macro_arg_tokens(rest, depth + 1, [lexer.LParen, ..acc])
        [lexer.RParen, ..rest] ->
          case depth == 1 {
            True -> #(list.reverse(acc), rest)
            False ->
              collect_macro_arg_tokens(rest, depth - 1, [lexer.RParen, ..acc])
          }
        [token, ..rest] -> collect_macro_arg_tokens(rest, depth, [token, ..acc])
      }
  }
}

/// Extract the argument name from macro arg tokens.
/// Handles: Ident(name), StringLit(name), QuotedIdent(name).
fn extract_arg_name(tokens: List(lexer.Token)) -> String {
  case tokens {
    [lexer.Ident(name)] -> name
    [lexer.StringLit(name)] -> name
    [lexer.QuotedIdent(name)] -> name
    _ ->
      // Fallback: render tokens to text
      tokens
      |> list.filter_map(fn(t) {
        case t {
          lexer.Ident(n) -> Ok(n)
          lexer.StringLit(n) -> Ok(n)
          lexer.QuotedIdent(n) -> Ok(n)
          _ -> Error(Nil)
        }
      })
      |> string.join("")
  }
}

fn engine_placeholder(engine: model.Engine, index: Int) -> String {
  case engine {
    model.PostgreSQL -> "$" <> int.to_string(index)
    model.MySQL -> "?"
    model.SQLite -> "?" <> int.to_string(index)
  }
}
