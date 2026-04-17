import gleam/list
import gleam/option
import gleam/string
import sqlode/char_utils.{
  is_alnum_or_underscore, is_alpha_or_underscore, is_digit,
}
import sqlode/model

/// Options for controlling how tokens are rendered back to text.
pub type TokenRenderOptions {
  TokenRenderOptions(
    /// When True, SQL keywords are rendered in UPPERCASE.
    uppercase_keywords: Bool,
    /// When True, quoted identifiers keep their quotes and string
    /// literals escape embedded single-quotes.
    preserve_quotes: Bool,
    /// When set, use engine-specific quote style for identifiers:
    /// MySQL → backticks, PostgreSQL/SQLite → double quotes.
    engine: option.Option(model.Engine),
  )
}

/// A SQL token produced by the lexer.
pub type Token {
  /// SQL keyword (lowercased): SELECT, FROM, CREATE, etc.
  Keyword(String)
  /// Unquoted identifier: table_name, column_name
  Ident(String)
  /// Quoted identifier: "name", `name`, [name] (quotes stripped)
  QuotedIdent(String)
  /// String literal (quotes stripped): 'value', $$dollar$$
  StringLit(String)
  /// Numeric literal: 42, 3.14
  NumberLit(String)
  /// Parameter placeholder: $1, ?, :name, @name
  Placeholder(String)
  /// Operator: =, <>, ::, ->, ||, etc.
  Operator(String)
  LParen
  RParen
  Comma
  Semicolon
  Dot
  Star
}

/// Tokenize a SQL string into a list of tokens.
/// Comments are stripped. String literals and quoted identifiers are preserved
/// as single tokens with their content.
pub fn tokenize(sql: String, engine: model.Engine) -> List(Token) {
  let graphemes = string.to_graphemes(sql)
  do_tokenize(graphemes, engine, [])
  |> list.reverse
}

fn do_tokenize(
  input: List(String),
  engine: model.Engine,
  acc: List(Token),
) -> List(Token) {
  case input {
    [] -> acc
    [g, ..rest] ->
      case g {
        // Whitespace — skip
        " " | "\t" | "\n" | "\r" -> do_tokenize(rest, engine, acc)

        // Line comment: --
        "-" ->
          case rest {
            ["-", ..after_dash] -> {
              let remaining = skip_line_comment(after_dash)
              do_tokenize(remaining, engine, acc)
            }
            _ -> {
              let #(op, remaining) = read_operator([g, ..rest])
              do_tokenize(remaining, engine, [Operator(op), ..acc])
            }
          }

        // Block comment: /* ... */ or MySQL # comment
        "/" ->
          case rest {
            ["*", ..after_star] -> {
              let remaining = skip_block_comment(after_star)
              do_tokenize(remaining, engine, acc)
            }
            _ -> do_tokenize(rest, engine, [Operator("/"), ..acc])
          }

        "#" ->
          case engine {
            model.MySQL -> {
              let remaining = skip_line_comment(rest)
              do_tokenize(remaining, engine, acc)
            }
            _ -> {
              let #(op, remaining) = read_operator([g, ..rest])
              do_tokenize(remaining, engine, [Operator(op), ..acc])
            }
          }

        // Single-quoted string literal
        "'" -> {
          let #(content, remaining) = read_single_quoted_string(rest, [])
          do_tokenize(remaining, engine, [StringLit(content), ..acc])
        }

        // Dollar-quoted string (PostgreSQL)
        "$" ->
          case engine {
            model.PostgreSQL ->
              case try_dollar_tag_lex(rest) {
                Ok(#(tag, after_tag)) -> {
                  let #(content, remaining) =
                    read_dollar_quoted_string(after_tag, tag, [])
                  do_tokenize(remaining, engine, [StringLit(content), ..acc])
                }
                Error(_) -> {
                  // Could be placeholder $1, $name
                  let #(token, remaining) =
                    read_placeholder_or_ident(["$", ..rest])
                  do_tokenize(remaining, engine, [token, ..acc])
                }
              }
            _ -> {
              // SQLite $name placeholder
              let #(token, remaining) = read_placeholder_or_ident(["$", ..rest])
              do_tokenize(remaining, engine, [token, ..acc])
            }
          }

        // Double-quoted identifier (PostgreSQL/SQLite) or string (MySQL)
        "\"" ->
          case engine {
            model.MySQL -> {
              let #(content, remaining) = read_quoted(rest, "\"", [])
              do_tokenize(remaining, engine, [StringLit(content), ..acc])
            }
            _ -> {
              let #(content, remaining) = read_quoted(rest, "\"", [])
              do_tokenize(remaining, engine, [QuotedIdent(content), ..acc])
            }
          }

        // Backtick-quoted identifier (MySQL)
        "`" -> {
          let #(content, remaining) = read_quoted(rest, "`", [])
          do_tokenize(remaining, engine, [QuotedIdent(content), ..acc])
        }

        // Bracket-quoted identifier (SQLite)
        "[" ->
          case engine {
            model.SQLite -> {
              let #(content, remaining) = read_quoted(rest, "]", [])
              do_tokenize(remaining, engine, [QuotedIdent(content), ..acc])
            }
            _ -> {
              let #(op, remaining) = read_operator([g, ..rest])
              do_tokenize(remaining, engine, [Operator(op), ..acc])
            }
          }

        // Single-char tokens
        "(" -> do_tokenize(rest, engine, [LParen, ..acc])
        ")" -> do_tokenize(rest, engine, [RParen, ..acc])
        "," -> do_tokenize(rest, engine, [Comma, ..acc])
        ";" -> do_tokenize(rest, engine, [Semicolon, ..acc])
        "*" -> do_tokenize(rest, engine, [Star, ..acc])

        // Dot
        "." ->
          case rest {
            [next, ..] ->
              case is_digit(next) {
                // .5 → numeric literal
                True -> {
                  let #(num, remaining) = read_number(rest, [g])
                  do_tokenize(remaining, engine, [NumberLit(num), ..acc])
                }
                False -> do_tokenize(rest, engine, [Dot, ..acc])
              }
            _ -> do_tokenize(rest, engine, [Dot, ..acc])
          }

        // Placeholder: ?, :name, @name
        "?" -> {
          let #(ph, remaining) = read_placeholder_question(rest, [g])
          do_tokenize(remaining, engine, [Placeholder(ph), ..acc])
        }
        ":" ->
          case rest {
            // PostgreSQL :: cast operator
            [":", ..after_colon] ->
              do_tokenize(after_colon, engine, [Operator("::"), ..acc])
            [next, ..] ->
              case is_alpha_or_underscore(next) {
                True -> {
                  let #(ph, remaining) = read_word(rest, [g])
                  do_tokenize(remaining, engine, [Placeholder(ph), ..acc])
                }
                False -> do_tokenize(rest, engine, [Operator(":"), ..acc])
              }
            _ -> do_tokenize(rest, engine, [Operator(":"), ..acc])
          }
        "@" ->
          case rest {
            [next, ..] ->
              case is_alpha_or_underscore(next) {
                True -> {
                  let #(ph, remaining) = read_word(rest, [g])
                  do_tokenize(remaining, engine, [Placeholder(ph), ..acc])
                }
                False -> do_tokenize(rest, engine, [Operator("@"), ..acc])
              }
            _ -> do_tokenize(rest, engine, [Operator("@"), ..acc])
          }

        // Numbers
        _ ->
          case is_digit(g) {
            True -> {
              let #(num, remaining) = read_number(rest, [g])
              do_tokenize(remaining, engine, [NumberLit(num), ..acc])
            }
            False ->
              case is_alpha_or_underscore(g) {
                True -> {
                  let #(word, remaining) = read_word(rest, [g])
                  let token = classify_word(word)
                  do_tokenize(remaining, engine, [token, ..acc])
                }
                // Operators and other characters
                False -> {
                  let #(op, remaining) = read_operator([g, ..rest])
                  do_tokenize(remaining, engine, [Operator(op), ..acc])
                }
              }
          }
      }
  }
}

// --- Comment helpers ---

fn skip_line_comment(input: List(String)) -> List(String) {
  case input {
    [] -> []
    ["\n", ..rest] -> rest
    [_, ..rest] -> skip_line_comment(rest)
  }
}

fn skip_block_comment(input: List(String)) -> List(String) {
  skip_block_comment_loop(input, 1)
}

fn skip_block_comment_loop(input: List(String), depth: Int) -> List(String) {
  case input {
    [] -> []
    _ ->
      case depth <= 0 {
        True -> input
        False ->
          case input {
            ["*", "/", ..rest] -> skip_block_comment_loop(rest, depth - 1)
            ["/", "*", ..rest] -> skip_block_comment_loop(rest, depth + 1)
            [_, ..rest] -> skip_block_comment_loop(rest, depth)
            [] -> []
          }
      }
  }
}

// --- String literal helpers ---

fn read_single_quoted_string(
  input: List(String),
  acc: List(String),
) -> #(String, List(String)) {
  case input {
    [] -> #(acc |> list.reverse |> string.concat, [])
    ["'", "'", ..rest] ->
      // Escaped quote '' → single '
      read_single_quoted_string(rest, ["'", ..acc])
    ["'", ..rest] ->
      // End of string
      #(acc |> list.reverse |> string.concat, rest)
    [g, ..rest] -> read_single_quoted_string(rest, [g, ..acc])
  }
}

fn read_dollar_quoted_string(
  input: List(String),
  tag: String,
  acc: List(String),
) -> #(String, List(String)) {
  case input {
    [] -> #(acc |> list.reverse |> string.concat, [])
    ["$", ..rest] ->
      case try_match_closing_dollar_tag_lex(rest, tag) {
        Ok(remaining) -> #(acc |> list.reverse |> string.concat, remaining)
        Error(_) -> read_dollar_quoted_string(rest, tag, ["$", ..acc])
      }
    [g, ..rest] -> read_dollar_quoted_string(rest, tag, [g, ..acc])
  }
}

fn try_dollar_tag_lex(
  chars: List(String),
) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..rest] -> Ok(#("", rest))
    [c, ..rest] ->
      case is_alpha_or_underscore(c) {
        True -> read_dollar_tag_chars_lex(rest, [c])
        False -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

fn read_dollar_tag_chars_lex(
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
      case is_alnum_or_underscore(c) {
        True -> read_dollar_tag_chars_lex(rest, [c, ..acc])
        False -> Error(Nil)
      }
  }
}

fn try_match_closing_dollar_tag_lex(
  chars: List(String),
  tag: String,
) -> Result(List(String), Nil) {
  let tag_chars = string.to_graphemes(tag)
  match_tag_then_dollar_lex(chars, tag_chars)
}

fn match_tag_then_dollar_lex(
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
          match_tag_then_dollar_lex(chars_rest, tag_rest)
        _ -> Error(Nil)
      }
  }
}

fn read_quoted(
  input: List(String),
  closer: String,
  acc: List(String),
) -> #(String, List(String)) {
  case input {
    [] -> #(acc |> list.reverse |> string.concat, [])
    // SQL standard: a doubled closer inside the quotes is an escaped literal.
    // SQLite bracket identifiers ([...]) have no escape mechanism for ].
    [g, g2, ..rest] if g == closer && g2 == closer && closer != "]" ->
      read_quoted(rest, closer, [g, ..acc])
    [g, ..rest] ->
      case g == closer {
        True -> #(acc |> list.reverse |> string.concat, rest)
        False -> read_quoted(rest, closer, [g, ..acc])
      }
  }
}

// --- Word/identifier helpers ---

fn read_word(input: List(String), acc: List(String)) -> #(String, List(String)) {
  case input {
    [g, ..rest] ->
      case is_alnum_or_underscore(g) {
        True -> read_word(rest, [g, ..acc])
        False -> #(acc |> list.reverse |> string.concat, input)
      }
    [] -> #(acc |> list.reverse |> string.concat, [])
  }
}

fn classify_word(word: String) -> Token {
  let lowered = string.lowercase(word)
  case is_sql_keyword(lowered) {
    True -> Keyword(lowered)
    False -> Ident(word)
  }
}

fn is_sql_keyword(word: String) -> Bool {
  case word {
    "select"
    | "from"
    | "where"
    | "and"
    | "or"
    | "not"
    | "in"
    | "is"
    | "null"
    | "as"
    | "on"
    | "join"
    | "inner"
    | "left"
    | "right"
    | "full"
    | "outer"
    | "cross"
    | "natural"
    | "using"
    | "order"
    | "by"
    | "group"
    | "having"
    | "limit"
    | "offset"
    | "union"
    | "intersect"
    | "except"
    | "all"
    | "distinct"
    | "insert"
    | "into"
    | "values"
    | "update"
    | "set"
    | "delete"
    | "create"
    | "table"
    | "view"
    | "type"
    | "index"
    | "alter"
    | "add"
    | "column"
    | "drop"
    | "if"
    | "exists"
    | "primary"
    | "key"
    | "foreign"
    | "references"
    | "unique"
    | "check"
    | "default"
    | "constraint"
    | "cascade"
    | "restrict"
    | "no"
    | "action"
    | "autoincrement"
    | "serial"
    | "bigserial"
    | "smallserial"
    | "returning"
    | "case"
    | "when"
    | "then"
    | "else"
    | "end"
    | "cast"
    | "between"
    | "like"
    | "ilike"
    | "with"
    | "recursive"
    | "temporary"
    | "temp"
    | "unlogged"
    | "true"
    | "false"
    | "asc"
    | "desc"
    | "nulls"
    | "first"
    | "last"
    | "over"
    | "partition"
    | "window"
    | "row"
    | "rows"
    | "range"
    | "preceding"
    | "following"
    | "current"
    | "unbounded"
    | "enum"
    | "replace"
    | "conflict"
    | "do"
    | "nothing"
    | "begin"
    | "commit"
    | "rollback"
    | "transaction"
    | "for"
    | "each"
    | "trigger"
    | "execute"
    | "procedure"
    | "function"
    | "returns"
    | "language"
    | "volatile"
    | "stable"
    | "immutable"
    | "security"
    | "definer"
    | "invoker"
    | "grant"
    | "revoke"
    | "to"
    | "schema"
    | "database"
    | "extension"
    | "only"
    | "lateral"
    | "any"
    | "some"
    | "array"
    | "of"
    | "collate" -> True
    _ -> False
  }
}

// --- Number helpers ---

fn read_number(
  input: List(String),
  acc: List(String),
) -> #(String, List(String)) {
  case input {
    [g, ..rest] ->
      case is_digit(g) || g == "." {
        True -> read_number(rest, [g, ..acc])
        False ->
          case g == "e" || g == "E" {
            True ->
              case rest {
                ["+", ..] | ["-", ..] ->
                  read_number(list.drop(rest, 1), [
                    case rest {
                      [s, ..] -> s
                      _ -> ""
                    },
                    g,
                    ..acc
                  ])
                _ -> read_number(rest, [g, ..acc])
              }
            False -> #(acc |> list.reverse |> string.concat, input)
          }
      }
    [] -> #(acc |> list.reverse |> string.concat, [])
  }
}

// --- Placeholder helpers ---

fn read_placeholder_or_ident(input: List(String)) -> #(Token, List(String)) {
  case input {
    ["$", ..rest] -> {
      let #(word, remaining) = read_word(rest, ["$"])
      #(Placeholder(word), remaining)
    }
    _ -> #(Operator("$"), input)
  }
}

fn read_placeholder_question(
  input: List(String),
  acc: List(String),
) -> #(String, List(String)) {
  case input {
    [g, ..rest] ->
      case is_digit(g) {
        True -> read_placeholder_question(rest, [g, ..acc])
        False -> #(acc |> list.reverse |> string.concat, input)
      }
    [] -> #(acc |> list.reverse |> string.concat, [])
  }
}

// --- Operator helpers ---

fn read_operator(input: List(String)) -> #(String, List(String)) {
  case input {
    // Multi-char operators
    ["<", ">", ..rest] -> #("<>", rest)
    ["<", "=", ..rest] -> #("<=", rest)
    [">", "=", ..rest] -> #(">=", rest)
    ["!", "=", ..rest] -> #("!=", rest)
    ["|", "|", ..rest] -> #("||", rest)
    ["-", ">", ">", ..rest] -> #("->>", rest)
    ["-", ">", ..rest] -> #("->", rest)
    // Single-char operators
    [g, ..rest] -> #(g, rest)
    [] -> #("", [])
  }
}

/// Render a list of tokens back to a SQL string with smart spacing.
pub fn tokens_to_string(
  tokens: List(Token),
  options: TokenRenderOptions,
) -> String {
  tokens_to_string_loop(tokens, [], options)
  |> list.reverse
  |> string.concat
}

fn tokens_to_string_loop(
  tokens: List(Token),
  acc: List(String),
  options: TokenRenderOptions,
) -> List(String) {
  case tokens {
    [] -> acc
    [token, ..rest] -> {
      let s = token_to_string(token, options)
      let with_space = case acc, token {
        _, Comma | _, Semicolon | _, LParen | _, RParen | _, Dot | _, Star -> [
          s,
          ..acc
        ]
        ["(", ..], _ | [".", ..], _ -> [s, ..acc]
        _, Operator("[") -> [s, ..acc]
        ["]", ..], _ | ["[", ..], _ -> [s, ..acc]
        [], _ -> [s]
        _, _ -> [s, " ", ..acc]
      }
      tokens_to_string_loop(rest, with_space, options)
    }
  }
}

fn token_to_string(token: Token, options: TokenRenderOptions) -> String {
  case token {
    Keyword(k) ->
      case options.uppercase_keywords {
        True -> string.uppercase(k)
        False -> k
      }
    Ident(name) -> name
    QuotedIdent(name) ->
      case options.preserve_quotes {
        True ->
          case options.engine {
            option.Some(model.MySQL) -> "`" <> name <> "`"
            _ -> "\"" <> name <> "\""
          }
        False -> name
      }
    StringLit(value) ->
      case options.preserve_quotes {
        True -> "'" <> string.replace(value, "'", "''") <> "'"
        False -> "'" <> value <> "'"
      }
    NumberLit(n) -> n
    Placeholder(p) -> p
    Operator(op) -> op
    LParen -> "("
    RParen -> ")"
    Comma -> ","
    Semicolon -> ";"
    Dot -> "."
    Star -> "*"
  }
}
