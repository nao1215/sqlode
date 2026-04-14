import gleam/list
import gleam/regexp
import gleam/result
import gleam/string

pub type NamingContext {
  NamingContext(
    word_separator: regexp.Regexp,
    camel_case: regexp.Regexp,
    underscore_before_caps: regexp.Regexp,
  )
}

pub fn new() -> NamingContext {
  let assert Ok(word_separator) = regexp.from_string("[_\\-\\s./]+")
  let assert Ok(camel_case) =
    regexp.from_string("([A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+)")
  let assert Ok(underscore_before_caps) =
    regexp.from_string("([a-z0-9])([A-Z])")
  NamingContext(word_separator:, camel_case:, underscore_before_caps:)
}

pub fn to_pascal_case(ctx: NamingContext, input: String) -> String {
  input
  |> split_words(ctx)
  |> list.map(capitalize)
  |> string.join("")
}

pub fn to_snake_case(ctx: NamingContext, input: String) -> String {
  let result =
    input
    |> insert_underscores_before_caps(ctx)
    |> split_words(ctx)
    |> list.map(string.lowercase)
    |> string.join("_")

  escape_keyword(result)
}

fn capitalize(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> input
  }
}

fn split_words(input: String, ctx: NamingContext) -> List(String) {
  let parts = regexp.split(ctx.word_separator, input)

  parts
  |> list.flat_map(split_camel_case(_, ctx))
  |> list.filter(fn(part) { part != "" })
}

fn split_camel_case(input: String, ctx: NamingContext) -> List(String) {
  let matches = regexp.scan(ctx.camel_case, input)

  case matches {
    [] -> [input]
    _ ->
      list.map(matches, fn(match) {
        let regexp.Match(content, ..) = match
        content
      })
  }
}

fn insert_underscores_before_caps(input: String, ctx: NamingContext) -> String {
  regexp.replace(ctx.underscore_before_caps, input, "\\1_\\2")
}

pub fn normalize_identifier(identifier: String) -> String {
  identifier
  |> string.trim
  |> strip_identifier_quotes
  |> last_dot_segment
  |> strip_identifier_quotes
  |> string.lowercase
}

fn strip_identifier_quotes(identifier: String) -> String {
  let length = string.length(identifier)

  case length >= 2 {
    False -> identifier
    True -> {
      let first = string.slice(identifier, 0, 1)
      let last = string.slice(identifier, length - 1, 1)

      let is_quoted =
        { first == "\"" && last == "\"" }
        || { first == "`" && last == "`" }
        || { first == "[" && last == "]" }

      case is_quoted {
        True -> string.slice(identifier, 1, length - 2)
        False -> identifier
      }
    }
  }
}

fn last_dot_segment(identifier: String) -> String {
  case string.contains(identifier, ".") {
    True ->
      identifier
      |> string.split(".")
      |> list.last
      |> result.unwrap(identifier)
    False -> identifier
  }
}

pub fn singularize(word: String) -> String {
  let lower = string.lowercase(word)
  case lower {
    // Irregular plurals
    "people" -> apply_case(word, "person")
    "children" -> apply_case(word, "child")
    "men" -> apply_case(word, "man")
    "women" -> apply_case(word, "woman")
    "mice" -> apply_case(word, "mouse")
    "geese" -> apply_case(word, "goose")
    "teeth" -> apply_case(word, "tooth")
    "feet" -> apply_case(word, "foot")
    "data" -> apply_case(word, "datum")
    "media" -> apply_case(word, "medium")
    "criteria" -> apply_case(word, "criterion")
    // Uncountable / already singular
    "news"
    | "series"
    | "species"
    | "status"
    | "bus"
    | "alias"
    | "address"
    | "campus"
    | "bonus"
    | "process"
    | "analysis"
    | "basis"
    | "crisis"
    | "diagnosis"
    | "thesis"
    | "virus"
    | "focus"
    | "consensus"
    | "corpus" -> word
    _ -> singularize_regular(word, lower)
  }
}

fn singularize_regular(word: String, lower: String) -> String {
  case string.length(word) <= 2 {
    True -> word
    False -> singularize_by_suffix(word, lower)
  }
}

fn singularize_by_suffix(word: String, lower: String) -> String {
  case string.ends_with(lower, "ies") {
    True -> string.drop_end(word, 3) <> apply_suffix_case(word, "y")
    False ->
      case string.ends_with(lower, "ves") {
        True -> string.drop_end(word, 3) <> apply_suffix_case(word, "f")
        False ->
          case
            string.ends_with(lower, "sses")
            || string.ends_with(lower, "shes")
            || string.ends_with(lower, "ches")
            || string.ends_with(lower, "xes")
            || string.ends_with(lower, "zes")
          {
            True -> string.drop_end(word, 2)
            False ->
              case string.ends_with(lower, "ss") {
                True -> word
                False ->
                  case string.ends_with(lower, "s") {
                    True -> string.drop_end(word, 1)
                    False -> word
                  }
              }
          }
      }
  }
}

fn apply_case(original: String, replacement: String) -> String {
  case string.uppercase(original) == original {
    True -> string.uppercase(replacement)
    False ->
      case
        string.first(original)
        |> result.map(fn(c) { string.uppercase(c) == c })
        |> result.unwrap(False)
      {
        True -> capitalize(replacement)
        False -> replacement
      }
  }
}

fn apply_suffix_case(word: String, suffix: String) -> String {
  let last_char =
    string.slice(word, string.length(word) - 1, 1)
    |> string.lowercase
  case last_char == string.uppercase(last_char) {
    True -> string.uppercase(suffix)
    False -> suffix
  }
}

fn escape_keyword(name: String) -> String {
  case name {
    "as"
    | "assert"
    | "auto"
    | "case"
    | "const"
    | "external"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "panic"
    | "pub"
    | "test"
    | "todo"
    | "type"
    | "use" -> name <> "_"
    _ -> name
  }
}
