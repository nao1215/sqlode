import gleam/string

pub fn escape_string(input: String) -> String {
  input
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// Derive the Gleam module path from the output directory.
/// Strips the "src/" prefix so imports match the actual file location.
/// e.g. "src/db" -> "db", "/abs/path/src/db" -> "db"
pub fn out_to_module_path(out: String) -> String {
  case string.starts_with(out, "src/") {
    True -> string.drop_start(out, 4)
    False ->
      case string.split(out, "/src/") {
        [_, after] -> after
        _ -> out
      }
  }
}
