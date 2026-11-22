import gleam/list
import gleam/string

pub fn is_digit(g: String) -> Bool {
  case g {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// ASCII letters and every non-ASCII character. SQL engines accept
/// letters from any script in unquoted identifiers (`naïve`, `名前`),
/// so the lexer reads them as part of a word instead of splitting the
/// word into fragments. A grapheme made of several code points (a
/// letter with a combining mark) counts when its first one does.
fn is_alpha(g: String) -> Bool {
  let cp = case string.to_utf_codepoints(g) {
    [cp, ..] -> string.utf_codepoint_to_int(cp)
    [] -> 0
  }
  { cp >= 65 && cp <= 90 } || { cp >= 97 && cp <= 122 } || cp >= 128
}

pub fn is_uppercase_letter(g: String) -> Bool {
  let cp = single_codepoint(g)
  cp >= 65 && cp <= 90
}

pub fn is_lowercase_letter(g: String) -> Bool {
  let cp = single_codepoint(g)
  cp >= 97 && cp <= 122
}

/// The code point of a one-code-point grapheme, or 0.
fn single_codepoint(g: String) -> Int {
  case string.to_utf_codepoints(g) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> 0
  }
}

pub fn is_alpha_or_underscore(g: String) -> Bool {
  is_alpha(g) || g == "_"
}

pub fn is_alnum_or_underscore(g: String) -> Bool {
  is_alpha(g) || is_digit(g) || g == "_"
}

pub fn all_digits(value: String) -> Bool {
  value != "" && list.all(string.to_graphemes(value), is_digit)
}
