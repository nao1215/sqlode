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
          let masked = mask_sql(engine, sql)
          let #(at_expanded, at_masked, at_macros, next_idx) =
            expand_at_name_shorthands(engine, sql, masked)
          let #(expanded_sql, expanded_macros) =
            expand_macros(engine, at_expanded, at_masked, next_idx)
          let macros = list.append(at_macros, expanded_macros)
          Ok([
            model.ParsedQuery(
              name:,
              function_name:,
              command:,
              sql: expanded_sql,
              source_path: path,
              param_count: count_parameters(engine, expanded_sql),
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
  case string.starts_with(line, "-- name:") {
    False -> Ok(None)
    True -> {
      let rest =
        line
        |> string.replace("-- name:", "")
        |> string.trim

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
            detail: "expected '-- name: <Name> <command>' where command is one of: :one, :many, :exec, :execresult, :execrows, :execlastid",
          ))
      }
    }
  }
}

fn is_skip_annotation(line: String) -> Bool {
  line == "-- sqlode:skip"
}

fn count_parameters(engine: model.Engine, sql: String) -> Int {
  let placeholders =
    lexer.tokenize(sql, engine)
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
// @name expansion (token-detected, string-replaced)
// ============================================================

/// Expand @name shorthands. Uses masked SQL for position-safe detection,
/// original SQL for replacement to preserve formatting.
fn expand_at_name_shorthands(
  engine: model.Engine,
  sql: String,
  masked: String,
) -> #(String, String, List(model.Macro), Int) {
  case engine {
    model.MySQL -> #(sql, masked, [], 1)
    _ -> {
      let at_positions = find_at_names(masked)
      case at_positions {
        [] -> #(sql, masked, [], 1)
        _ ->
          expand_at_positions(
            engine,
            sql,
            masked,
            at_positions,
            1,
            dict.new(),
            [],
          )
      }
    }
  }
}

/// Find all @name positions in masked SQL (no regex).
fn find_at_names(masked: String) -> List(#(Int, String)) {
  find_at_loop(string.to_graphemes(masked), 0, [])
  |> list.reverse
}

fn find_at_loop(
  chars: List(String),
  pos: Int,
  acc: List(#(Int, String)),
) -> List(#(Int, String)) {
  case chars {
    [] -> acc
    ["@", ..rest] ->
      case read_identifier_chars(rest, []) {
        #("", _) -> find_at_loop(rest, pos + 1, acc)
        #(name, remaining) -> {
          let full = "@" <> name
          find_at_loop(remaining, pos + string.length(full), [
            #(pos, name),
            ..acc
          ])
        }
      }
    [c, ..rest] -> find_at_loop(rest, pos + string.length(c), acc)
  }
}

fn read_identifier_chars(
  chars: List(String),
  acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case is_ident_char(c) {
        True -> read_identifier_chars(rest, [c, ..acc])
        False -> #(acc |> list.reverse |> string.concat, chars)
      }
    [] -> #(acc |> list.reverse |> string.concat, [])
  }
}

fn is_ident_char(c: String) -> Bool {
  let cp = case string.to_utf_codepoints(c) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> 0
  }
  { cp >= 65 && cp <= 90 }
  || { cp >= 97 && cp <= 122 }
  || { cp >= 48 && cp <= 57 }
  || c == "_"
}

fn expand_at_positions(
  engine: model.Engine,
  sql: String,
  masked: String,
  positions: List(#(Int, String)),
  idx: Int,
  seen: dict.Dict(String, Int),
  macro_acc: List(model.Macro),
) -> #(String, String, List(model.Macro), Int) {
  case positions {
    [] -> #(sql, masked, list.reverse(macro_acc), idx)
    [#(_pos, name), ..rest] ->
      case engine, dict.get(seen, name) {
        model.SQLite, Ok(existing_idx) -> {
          let placeholder = engine_placeholder(engine, existing_idx)
          let pattern = "@" <> name
          let #(new_sql, new_masked) =
            replace_first_in_masked(sql, masked, pattern, placeholder)
          expand_at_positions(
            engine,
            new_sql,
            new_masked,
            rest,
            idx,
            seen,
            macro_acc,
          )
        }
        _, _ -> {
          let placeholder = engine_placeholder(engine, idx)
          let pattern = "@" <> name
          let #(new_sql, new_masked) =
            replace_first_in_masked(sql, masked, pattern, placeholder)
          let new_seen = case engine {
            model.SQLite -> dict.insert(seen, name, idx)
            _ -> seen
          }
          expand_at_positions(
            engine,
            new_sql,
            new_masked,
            rest,
            idx + 1,
            new_seen,
            [model.MacroArg(index: idx, name:), ..macro_acc],
          )
        }
      }
  }
}

// ============================================================
// Macro expansion (token-detected, string-replaced)
// ============================================================

/// Expand sqlode.arg/narg/slice macros. Detects patterns in masked SQL
/// without regex, replaces in original SQL to preserve formatting.
fn expand_macros(
  engine: model.Engine,
  sql: String,
  masked: String,
  start_idx: Int,
) -> #(String, List(model.Macro)) {
  let macro_positions = find_macro_patterns(masked)
  case macro_positions {
    [] -> #(sql, [])
    _ ->
      expand_macro_positions(
        engine,
        sql,
        masked,
        macro_positions,
        start_idx,
        [],
      )
  }
}

type MacroMatch {
  MacroMatch(kind: String, full_pattern: String)
}

/// Find sqlode.arg|narg|slice(...) patterns in masked text (no regex).
fn find_macro_patterns(masked: String) -> List(MacroMatch) {
  find_macro_loop(masked, [])
  |> list.reverse
}

fn find_macro_loop(masked: String, acc: List(MacroMatch)) -> List(MacroMatch) {
  case string.split_once(masked, "sqlode.") {
    Error(_) -> acc
    Ok(#(_before, after)) -> {
      // Check for arg|narg|slice after "sqlode."
      case try_parse_macro_kind(after) {
        Some(#(kind, after_kind)) ->
          case string.split_once(after_kind, ")") {
            Ok(#(arg_content, rest)) -> {
              let full = "sqlode." <> kind <> "(" <> arg_content <> ")"
              find_macro_loop(rest, [
                MacroMatch(kind:, full_pattern: full),
                ..acc
              ])
            }
            Error(_) -> find_macro_loop(after, acc)
          }
        None -> find_macro_loop(after, acc)
      }
    }
  }
}

fn try_parse_macro_kind(s: String) -> Option(#(String, String)) {
  case string.starts_with(s, "arg(") {
    True -> Some(#("arg", string.drop_start(s, 4)))
    False ->
      case string.starts_with(s, "narg(") {
        True -> Some(#("narg", string.drop_start(s, 5)))
        False ->
          case string.starts_with(s, "slice(") {
            True -> Some(#("slice", string.drop_start(s, 6)))
            False -> None
          }
      }
  }
}

fn expand_macro_positions(
  engine: model.Engine,
  sql: String,
  masked: String,
  matches: List(MacroMatch),
  idx: Int,
  macro_acc: List(model.Macro),
) -> #(String, List(model.Macro)) {
  case matches {
    [] -> #(sql, list.reverse(macro_acc))
    [match, ..rest] -> {
      let name = extract_macro_arg(sql, masked, match.full_pattern)
      let placeholder = engine_placeholder(engine, idx)
      let #(new_sql, new_masked) =
        replace_first_in_masked(sql, masked, match.full_pattern, placeholder)
      let macro_entry = case match.kind {
        "narg" -> model.MacroNarg(index: idx, name:)
        "slice" -> model.MacroSlice(index: idx, name:)
        _ -> model.MacroArg(index: idx, name:)
      }
      expand_macro_positions(engine, new_sql, new_masked, rest, idx + 1, [
        macro_entry,
        ..macro_acc
      ])
    }
  }
}

fn extract_macro_arg(
  sql: String,
  masked: String,
  masked_match: String,
) -> String {
  case string.split_once(masked, masked_match) {
    Ok(#(before, _)) -> {
      let pos = string.length(before)
      let span = string.slice(sql, pos, string.length(masked_match))
      case string.split_once(span, "(") {
        Ok(#(_, after_paren)) -> {
          let arg = string.drop_end(after_paren, 1)
          strip_quotes(string.trim(arg))
        }
        Error(_) -> ""
      }
    }
    Error(_) -> ""
  }
}

fn strip_quotes(name: String) -> String {
  case string.first(name) {
    Ok("'") | Ok("\"") -> string.slice(name, 1, string.length(name) - 2)
    _ -> name
  }
}

fn engine_placeholder(engine: model.Engine, index: Int) -> String {
  case engine {
    model.PostgreSQL -> "$" <> int.to_string(index)
    model.MySQL -> "?"
    model.SQLite -> "?" <> int.to_string(index)
  }
}

fn replace_first_in_masked(
  original: String,
  masked: String,
  pattern: String,
  replacement: String,
) -> #(String, String) {
  case string.split_once(masked, pattern) {
    Ok(#(before_masked, after_masked)) -> {
      let pos = string.length(before_masked)
      let before_orig = string.slice(original, 0, pos)
      let after_orig = string.drop_start(original, pos + string.length(pattern))
      #(
        before_orig <> replacement <> after_orig,
        before_masked <> replacement <> after_masked,
      )
    }
    Error(_) -> #(original, masked)
  }
}

// --- SQL masking (strip string literals and comments) ---

type MaskState {
  MaskNormal
  MaskSingleQuote
  MaskDoubleQuote
  MaskLineComment
  MaskBlockComment
  MaskDollarQuoted(tag: String)
}

fn mask_sql(engine: model.Engine, sql: String) -> String {
  let chars = string.to_graphemes(sql)
  do_mask(engine, chars, MaskNormal, [])
  |> list.reverse
  |> string.join("")
}

fn do_mask(
  engine: model.Engine,
  chars: List(String),
  state: MaskState,
  acc: List(String),
) -> List(String) {
  case state {
    MaskNormal ->
      case chars {
        [] -> acc
        ["'", ..rest] -> do_mask(engine, rest, MaskSingleQuote, [" ", ..acc])
        ["\"", ..rest] -> do_mask(engine, rest, MaskDoubleQuote, [" ", ..acc])
        ["-", "-", ..rest] ->
          do_mask(engine, rest, MaskLineComment, [" ", " ", ..acc])
        ["/", "*", ..rest] ->
          do_mask(engine, rest, MaskBlockComment, [" ", " ", ..acc])
        ["$", ..rest] ->
          case engine {
            model.PostgreSQL ->
              case try_dollar_tag(rest) {
                Ok(#(tag, after_tag)) -> {
                  let spaces = list.repeat(" ", string.length(tag) + 2)
                  do_mask(
                    engine,
                    after_tag,
                    MaskDollarQuoted(tag),
                    list.append(spaces, acc),
                  )
                }
                Error(_) -> do_mask(engine, rest, MaskNormal, ["$", ..acc])
              }
            _ -> do_mask(engine, rest, MaskNormal, ["$", ..acc])
          }
        [c, ..rest] -> do_mask(engine, rest, MaskNormal, [c, ..acc])
      }
    MaskSingleQuote ->
      case chars {
        [] -> acc
        ["'", "'", ..rest] ->
          do_mask(engine, rest, MaskSingleQuote, [" ", " ", ..acc])
        ["'", ..rest] -> do_mask(engine, rest, MaskNormal, [" ", ..acc])
        [_, ..rest] -> do_mask(engine, rest, MaskSingleQuote, [" ", ..acc])
      }
    MaskDoubleQuote ->
      case chars {
        [] -> acc
        ["\"", "\"", ..rest] ->
          do_mask(engine, rest, MaskDoubleQuote, [" ", " ", ..acc])
        ["\"", ..rest] -> do_mask(engine, rest, MaskNormal, [" ", ..acc])
        [_, ..rest] -> do_mask(engine, rest, MaskDoubleQuote, [" ", ..acc])
      }
    MaskLineComment ->
      case chars {
        [] -> acc
        ["\n", ..rest] -> do_mask(engine, rest, MaskNormal, ["\n", ..acc])
        [_, ..rest] -> do_mask(engine, rest, MaskLineComment, [" ", ..acc])
      }
    MaskBlockComment ->
      case chars {
        [] -> acc
        ["*", "/", ..rest] ->
          do_mask(engine, rest, MaskNormal, [" ", " ", ..acc])
        [_, ..rest] -> do_mask(engine, rest, MaskBlockComment, [" ", ..acc])
      }
    MaskDollarQuoted(tag) ->
      case chars {
        [] -> acc
        ["$", ..rest] ->
          case try_match_closing_dollar_tag(rest, tag) {
            Ok(remaining) -> {
              let spaces = list.repeat(" ", string.length(tag) + 2)
              do_mask(engine, remaining, MaskNormal, list.append(spaces, acc))
            }
            Error(_) ->
              do_mask(engine, rest, MaskDollarQuoted(tag), [" ", ..acc])
          }
        [_, ..rest] ->
          do_mask(engine, rest, MaskDollarQuoted(tag), [" ", ..acc])
      }
  }
}

fn try_dollar_tag(chars: List(String)) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..rest] -> Ok(#("", rest))
    [c, ..rest] ->
      case is_mask_alpha_or_underscore(c) {
        True -> read_dollar_tag_chars(rest, [c])
        False -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

fn read_dollar_tag_chars(
  chars: List(String),
  acc: List(String),
) -> Result(#(String, List(String)), Nil) {
  case chars {
    [] -> Error(Nil)
    ["$", ..rest] -> {
      let tag = acc |> list.reverse |> string.concat
      Ok(#(tag, rest))
    }
    [c, ..rest] ->
      case is_mask_alnum_or_underscore(c) {
        True -> read_dollar_tag_chars(rest, [c, ..acc])
        False -> Error(Nil)
      }
  }
}

fn try_match_closing_dollar_tag(
  chars: List(String),
  tag: String,
) -> Result(List(String), Nil) {
  let tag_chars = string.to_graphemes(tag)
  match_tag_then_dollar(chars, tag_chars)
}

fn match_tag_then_dollar(
  chars: List(String),
  tag_chars: List(String),
) -> Result(List(String), Nil) {
  case tag_chars {
    [] ->
      case chars {
        ["$", ..rest] -> Ok(rest)
        _ -> Error(Nil)
      }
    [expected, ..tag_rest] ->
      case chars {
        [actual, ..chars_rest] if actual == expected ->
          match_tag_then_dollar(chars_rest, tag_rest)
        _ -> Error(Nil)
      }
  }
}

fn is_mask_alpha_or_underscore(c: String) -> Bool {
  is_mask_alpha(c) || c == "_"
}

fn is_mask_alnum_or_underscore(c: String) -> Bool {
  is_mask_alpha(c) || is_mask_digit(c) || c == "_"
}

fn is_mask_alpha(c: String) -> Bool {
  let cp = case string.to_utf_codepoints(c) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> 0
  }
  { cp >= 65 && cp <= 90 } || { cp >= 97 && cp <= 122 }
}

fn is_mask_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
