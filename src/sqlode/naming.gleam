import gleam/list
import gleam/regexp
import gleam/string

type Regexes {
  Regexes(
    word_separator: regexp.Regexp,
    camel_case: regexp.Regexp,
    underscore_before_caps: regexp.Regexp,
  )
}

fn compile_regexes() -> Regexes {
  let assert Ok(word_separator) = regexp.from_string("[_\\-\\s./]+")
  let assert Ok(camel_case) =
    regexp.from_string("([A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+)")
  let assert Ok(underscore_before_caps) =
    regexp.from_string("([a-z0-9])([A-Z])")
  Regexes(word_separator:, camel_case:, underscore_before_caps:)
}

pub fn to_pascal_case(input: String) -> String {
  let re = compile_regexes()

  input
  |> split_words(re)
  |> list.map(capitalize)
  |> string.join("")
}

pub fn to_snake_case(input: String) -> String {
  let re = compile_regexes()
  let result =
    input
    |> insert_underscores_before_caps(re)
    |> split_words(re)
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

fn split_words(input: String, re: Regexes) -> List(String) {
  let parts = regexp.split(re.word_separator, input)

  parts
  |> list.flat_map(split_camel_case(_, re))
  |> list.filter(fn(part) { part != "" })
}

fn split_camel_case(input: String, re: Regexes) -> List(String) {
  let matches = regexp.scan(re.camel_case, input)

  case matches {
    [] -> [input]
    _ ->
      list.map(matches, fn(match) {
        let regexp.Match(content, ..) = match
        content
      })
  }
}

fn insert_underscores_before_caps(input: String, re: Regexes) -> String {
  regexp.replace(re.underscore_before_caps, input, "\\1_\\2")
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
