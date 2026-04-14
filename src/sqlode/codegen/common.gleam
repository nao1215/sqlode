import gleam/list
import gleam/result
import gleam/string
import sqlode/model

pub fn has_slices(params: List(model.QueryParam)) -> Bool {
  list.any(params, fn(p) { p.is_list })
}

pub fn queries_have_slices(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) { has_slices(query.params) })
}

pub fn queries_have_enum_params(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) {
    list.any(query.params, fn(param) {
      case param.scalar_type {
        model.EnumType(_) -> True
        _ -> False
      }
    })
  })
}

pub fn queries_have_enums(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) {
    list.any(query.params, fn(param) {
      case param.scalar_type {
        model.EnumType(_) -> True
        _ -> False
      }
    })
    || list.any(query.result_columns, fn(col) {
      case col {
        model.ResultColumn(scalar_type: model.EnumType(_), ..) -> True
        _ -> False
      }
    })
  })
}

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
      string.split(out, "/src/")
      |> list.last
      |> result.unwrap(out)
  }
}
