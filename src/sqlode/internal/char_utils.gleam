import gleam/string

pub fn is_digit(g: String) -> Bool {
  case g {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_alpha(g: String) -> Bool {
  let cp = case string.to_utf_codepoints(g) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> 0
  }
  { cp >= 65 && cp <= 90 } || { cp >= 97 && cp <= 122 }
}

pub fn is_uppercase_letter(g: String) -> Bool {
  let cp = case string.to_utf_codepoints(g) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> 0
  }
  cp >= 65 && cp <= 90
}

pub fn is_alpha_or_underscore(g: String) -> Bool {
  is_alpha(g) || g == "_"
}

pub fn is_alnum_or_underscore(g: String) -> Bool {
  is_alpha(g) || is_digit(g) || g == "_"
}

pub fn all_digits(value: String) -> Bool {
  case value {
    "" -> False
    _ -> all_digits_loop(value)
  }
}

fn all_digits_loop(value: String) -> Bool {
  case string.pop_grapheme(value) {
    Error(_) -> True
    Ok(#(char, rest)) ->
      case is_digit(char) {
        True -> all_digits_loop(rest)
        False -> False
      }
  }
}
