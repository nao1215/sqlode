import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/internal/lexer
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_ir
import sqlode/runtime

pub type ParseError {
  InvalidAnnotation(path: String, line: Int, detail: String)
  MissingSql(path: String, line: Int, name: String)
  InvalidPlaceholder(
    path: String,
    line: Int,
    name: String,
    engine: model.Engine,
    token: String,
  )
  WrongEngineUpsert(
    path: String,
    line: Int,
    name: String,
    engine: model.Engine,
    tail: String,
  )
  SparseNumberedPlaceholders(
    path: String,
    line: Int,
    name: String,
    indices: List(Int),
  )
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
) -> Result(List(query_ir.TokenizedQuery), ParseError) {
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
  parsed_rev: List(query_ir.TokenizedQuery),
  skip_next: Bool,
) -> Result(List(query_ir.TokenizedQuery), ParseError) {
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
  parsed_rev: List(query_ir.TokenizedQuery),
) -> Result(List(query_ir.TokenizedQuery), ParseError) {
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

          // Phase 4: Validate remaining raw placeholders match the engine
          case validate_placeholder_syntax(engine, tokens) {
            Error(token) ->
              Error(InvalidPlaceholder(
                path:,
                line: start_line,
                name:,
                engine:,
                token:,
              ))
            Ok(Nil) ->
              case validate_upsert_tails(engine, tokens) {
                Error(tail) ->
                  Error(WrongEngineUpsert(
                    path:,
                    line: start_line,
                    name:,
                    engine:,
                    tail:,
                  ))
                Ok(Nil) ->
                  case validate_sqlite_numbered_placeholders(engine, tokens) {
                    Error(indices) ->
                      Error(SparseNumberedPlaceholders(
                        path:,
                        line: start_line,
                        name:,
                        indices:,
                      ))
                    Ok(Nil) ->
                      Ok(finalize_ok(
                        parsed_rev,
                        name:,
                        function_name:,
                        command:,
                        path:,
                        tokens:,
                        macros:,
                        engine:,
                      ))
                  }
              }
          }
        }
      }
    }
  }
}

fn finalize_ok(
  parsed_rev: List(query_ir.TokenizedQuery),
  name name: String,
  function_name function_name: String,
  command command: runtime.QueryCommand,
  path path: String,
  tokens tokens: List(lexer.Token),
  macros macros: List(model.Macro),
  engine engine: model.Engine,
) -> List(query_ir.TokenizedQuery) {
  let expanded_sql =
    lexer.tokens_to_string(
      tokens,
      lexer.TokenRenderOptions(
        uppercase_keywords: False,
        preserve_quotes: True,
        engine: Some(engine),
      ),
    )
  let param_count = count_parameters_from_tokens(engine, tokens)
  let parsed =
    model.ParsedQuery(
      name:,
      function_name:,
      command:,
      sql: expanded_sql,
      source_path: path,
      param_count:,
      macros:,
    )
  [query_ir.TokenizedQuery(base: parsed, tokens: tokens), ..parsed_rev]
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
        [name, command_text] ->
          case string.starts_with(command_text, ":") {
            // Two parts where the second starts with ':' — this looks
            // like an intentional annotation (`-- name: GetUsers :many`).
            // Validate the command; an unrecognized command is still an error.
            True -> {
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
            // Second part doesn't start with ':' — not an annotation.
            False -> Ok(None)
          }
        // Anything else: `-- name:` followed by text that doesn't look
        // like an annotation (no colon-prefixed command).  Treat it as
        // an ordinary SQL comment so it doesn't split the current query.
        // Example: `-- name: this column stores the display name`
        _ -> Ok(None)
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
///
/// After macro/`@name` expansion every parameter is represented by a
/// `__sqlode_param_<idx>__` or `__sqlode_slice_<idx>__` marker, so the
/// parameter count is the highest index that appears. Raw engine
/// placeholders (`$1`, `?1`, bare `?`) written directly by the user are
/// also counted for back-compat with handwritten SQL.
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

  let #(markers, raw) =
    list.partition(placeholders, fn(p) { is_marker_placeholder(p) })

  // Marker placeholders count as distinct indices. The same marker may
  // appear multiple times (e.g. SQLite's `@name` reused in two positions)
  // but contributes one parameter slot per distinct index.
  let marker_count =
    markers
    |> list.filter_map(extract_marker_index)
    |> list.unique
    |> list.length

  // Raw engine placeholders written directly by the user keep the same
  // engine-specific counting the parser has always used (max index for
  // PostgreSQL, positional for MySQL, distinct-name-plus-bare-? for SQLite).
  let raw_count = case engine {
    model.PostgreSQL ->
      raw
      |> list.filter_map(fn(p) { string.replace(p, "$", "") |> int.parse })
      |> list.fold(0, fn(max_idx, v) {
        case v > max_idx {
          True -> v
          False -> max_idx
        }
      })
    model.MySQL -> list.length(raw)
    model.SQLite -> {
      let #(anon, named) = list.partition(raw, fn(p) { p == "?" })
      list.length(anon) + list.length(list.unique(named))
    }
  }

  marker_count + raw_count
}

fn is_marker_placeholder(p: String) -> Bool {
  string.starts_with(p, "__sqlode_param_")
  || string.starts_with(p, "__sqlode_slice_")
}

fn extract_marker_index(p: String) -> Result(Int, Nil) {
  let body = case string.starts_with(p, "__sqlode_param_") {
    True -> string.drop_start(p, 15)
    False ->
      case string.starts_with(p, "__sqlode_slice_") {
        True -> string.drop_start(p, 15)
        False -> p
      }
  }
  let without_suffix = case string.ends_with(body, "__") {
    True -> string.drop_end(body, 2)
    False -> body
  }
  int.parse(without_suffix)
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
    InvalidPlaceholder(path:, line:, name:, engine:, token:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": query "
      <> name
      <> ": placeholder `"
      <> token
      <> "` is not valid for engine "
      <> model.engine_to_string(engine)
      <> "; "
      <> allowed_placeholders_hint(engine)
    WrongEngineUpsert(path:, line:, name:, engine:, tail:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": query "
      <> name
      <> ": `"
      <> tail
      <> "` is not valid for engine "
      <> model.engine_to_string(engine)
      <> "; "
      <> upsert_hint(engine)
    SparseNumberedPlaceholders(path:, line:, name:, indices:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ": query "
      <> name
      <> ": sparse SQLite numbered placeholders "
      <> format_indices(indices)
      <> "; numbered placeholders must form a contiguous set starting from ?1 (e.g. ?1, ?2, ?3)"
  }
}

fn format_indices(indices: List(Int)) -> String {
  indices
  |> list.sort(int.compare)
  |> list.map(fn(i) { "?" <> int.to_string(i) })
  |> string.join(", ")
}

fn upsert_hint(engine: model.Engine) -> String {
  case engine {
    model.PostgreSQL ->
      "use `ON CONFLICT ... DO UPDATE` or `ON CONFLICT ... DO NOTHING`"
    model.SQLite ->
      "use `ON CONFLICT ... DO UPDATE` or `ON CONFLICT ... DO NOTHING`"
    model.MySQL -> "use `ON DUPLICATE KEY UPDATE`"
  }
}

fn allowed_placeholders_hint(engine: model.Engine) -> String {
  case engine {
    model.PostgreSQL ->
      "PostgreSQL accepts `$N` or sqlode macros (`@name`, `sqlode.arg(name)`)"
    model.MySQL ->
      "MySQL accepts positional `?` or sqlode macros (`sqlode.arg(name)`)"
    model.SQLite ->
      "SQLite accepts `?`, `?N`, `:name`, `@name`, `$name`, or sqlode macros (`sqlode.arg(name)`)"
  }
}

/// Validate that every raw placeholder token matches the configured engine.
/// Sqlode markers (`__sqlode_param_*` / `__sqlode_slice_*`) are always
/// accepted because they are produced by macro expansion and are rewritten
/// to engine-specific placeholders at prepare-time.
fn validate_placeholder_syntax(
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Result(Nil, String) {
  case tokens {
    [] -> Ok(Nil)
    [lexer.Placeholder(p), ..rest] ->
      case is_marker_placeholder(p) || is_valid_raw_placeholder(engine, p) {
        True -> validate_placeholder_syntax(engine, rest)
        False -> Error(p)
      }
    [_, ..rest] -> validate_placeholder_syntax(engine, rest)
  }
}

fn is_valid_raw_placeholder(engine: model.Engine, p: String) -> Bool {
  case engine {
    model.PostgreSQL -> is_dollar_numbered(p)
    model.MySQL -> p == "?"
    model.SQLite -> is_sqlite_placeholder_syntax(p)
  }
}

fn is_dollar_numbered(p: String) -> Bool {
  case string.starts_with(p, "$") {
    False -> False
    True -> is_positive_int(string.drop_start(p, 1))
  }
}

fn is_sqlite_placeholder_syntax(p: String) -> Bool {
  case p {
    "?" -> True
    _ ->
      case string.first(p) {
        Ok("?") -> is_positive_int(string.drop_start(p, 1))
        Ok(":") | Ok("@") | Ok("$") -> string.length(p) > 1
        _ -> False
      }
  }
}

fn is_positive_int(s: String) -> Bool {
  case int.parse(s) {
    Ok(n) if n > 0 -> True
    _ -> False
  }
}

/// Reject sparse SQLite numbered placeholders.
///
/// SQLite accepts `?N` with explicit indices, but sqlode's parameter count
/// and runtime expansion assume the declared indices form a contiguous set
/// starting from 1. A query that uses `?2` alone, or `?1` and `?3` with no
/// `?2`, passes lexing but yields generated metadata that does not match the
/// SQL text. Flag the mismatch at parse time so users can either renumber
/// their placeholders or switch to the bare `?` / `?1, ?2, ...` forms.
fn validate_sqlite_numbered_placeholders(
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Result(Nil, List(Int)) {
  case engine {
    model.SQLite -> {
      let indices =
        tokens
        |> list.filter_map(extract_sqlite_numbered_index)
        |> list.unique
      case indices {
        [] -> Ok(Nil)
        _ -> {
          let max_idx = list.fold(indices, 0, int.max)
          case max_idx == list.length(indices) {
            True -> Ok(Nil)
            False -> Error(indices)
          }
        }
      }
    }
    _ -> Ok(Nil)
  }
}

fn extract_sqlite_numbered_index(token: lexer.Token) -> Result(Int, Nil) {
  case token {
    lexer.Placeholder(p) ->
      case string.first(p), string.length(p) > 1 {
        Ok("?"), True -> int.parse(string.drop_start(p, 1))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Scan tokens for UPSERT tails that do not belong to the configured engine.
/// MySQL uses `ON DUPLICATE KEY UPDATE`; PostgreSQL and SQLite use `ON
/// CONFLICT ... DO UPDATE/NOTHING`. Accepting the wrong form silently leaks
/// dialect-incompatible SQL into generated code, so reject it early with a
/// diagnostic that names the offending tail.
fn validate_upsert_tails(
  engine: model.Engine,
  tokens: List(lexer.Token),
) -> Result(Nil, String) {
  case tokens {
    [] -> Ok(Nil)
    [lexer.Keyword("on"), lexer.Ident(word), ..rest] ->
      case string.lowercase(word), engine {
        "duplicate", model.MySQL -> validate_upsert_tails(engine, rest)
        "duplicate", _ -> Error("ON DUPLICATE KEY UPDATE")
        _, _ -> validate_upsert_tails(engine, rest)
      }
    [lexer.Keyword("on"), lexer.Keyword("conflict"), ..rest] ->
      case engine {
        model.MySQL -> Error("ON CONFLICT")
        _ -> validate_upsert_tails(engine, rest)
      }
    [_, ..rest] -> validate_upsert_tails(engine, rest)
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
      let placeholder = case kind {
        "slice" -> engine_slice_placeholder(engine, idx)
        _ -> engine_placeholder(engine, idx)
      }
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

fn engine_placeholder(_engine: model.Engine, index: Int) -> String {
  // Emit an engine-agnostic marker for every parameter position. The
  // runtime walks these markers and substitutes the engine-specific
  // placeholder (e.g. `$3`, `?3`, `?`) at prepare-time, which fixes
  // both MySQL's bare-`?` expansion and placeholder-like text inside
  // string literals or comments being rewritten by string.replace.
  runtime.param_marker(index)
}

fn engine_slice_placeholder(_engine: model.Engine, index: Int) -> String {
  runtime.slice_marker(index)
}
