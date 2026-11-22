import gleam/list
import gleam/string

pub fn is_digit(g: String) -> Bool {
  case g {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// ASCII letters, and outside ASCII the characters that can be part of
/// a word. SQL engines accept letters from any script in unquoted
/// identifiers (`naïve`, `名前`). Without a Unicode table the rule is
/// an approximation: every code point from U+0080 counts as a letter
/// or mark unless it is Unicode whitespace (`is_unicode_space`) or in
/// a punctuation or symbol range (`is_non_ascii_punctuation`). A
/// grapheme made of several code points (a letter with a combining
/// mark) counts when its first one does.
fn is_alpha(g: String) -> Bool {
  let cp = first_codepoint(g)
  { cp >= 65 && cp <= 90 }
  || { cp >= 97 && cp <= 122 }
  || { cp >= 128 && !is_space_codepoint(cp) && !is_non_ascii_punctuation(cp) }
}

/// Whitespace outside ASCII: NEL, no-break and the other Unicode
/// spaces, the zero-width space, the line and paragraph separators,
/// the ideographic space and the byte order mark (U+FEFF), which may
/// start a file.
pub fn is_unicode_space(g: String) -> Bool {
  is_space_codepoint(first_codepoint(g))
}

fn is_space_codepoint(cp: Int) -> Bool {
  cp == 0x85
  || cp == 0xA0
  || cp == 0x1680
  || { cp >= 0x2000 && cp <= 0x200B }
  || cp == 0x2028
  || cp == 0x2029
  || cp == 0x202F
  || cp == 0x205F
  || cp == 0x3000
  || cp == 0xFEFF
}

/// Punctuation and symbols outside ASCII: the Latin-1 signs (but not
/// ª, µ, º, which are letters), × and ÷, the General Punctuation to
/// Miscellaneous Symbols blocks, CJK punctuation (but not 々 〆 〇),
/// the CJK compatibility and small forms, fullwidth ASCII punctuation
/// and the emoji and pictograph planes.
fn is_non_ascii_punctuation(cp: Int) -> Bool {
  { cp >= 0x80 && cp <= 0xBF && cp != 0xAA && cp != 0xB5 && cp != 0xBA }
  || cp == 0xD7
  || cp == 0xF7
  || { cp >= 0x2000 && cp <= 0x2BFF }
  || { cp >= 0x3000 && cp <= 0x303F && { cp < 0x3005 || cp > 0x3007 } }
  || { cp >= 0xFE30 && cp <= 0xFE6F }
  || { cp >= 0xFF01 && cp <= 0xFF0F }
  || { cp >= 0xFF1A && cp <= 0xFF20 }
  || { cp >= 0xFF3B && cp <= 0xFF40 }
  || { cp >= 0xFF5B && cp <= 0xFF65 }
  || { cp >= 0x1F000 && cp <= 0x1FAFF }
}

fn first_codepoint(g: String) -> Int {
  case string.to_utf_codepoints(g) {
    [cp, ..] -> string.utf_codepoint_to_int(cp)
    [] -> 0
  }
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
