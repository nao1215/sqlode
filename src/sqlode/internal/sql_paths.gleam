//// Shared `.sql` path expansion used by `generate` and `verify`.
////
//// A configured `schema` or `queries` entry may be either a direct
//// path to a `.sql` file or a directory of `.sql` files. This
//// module applies the expansion rules both commands rely on so the
//// CLI presents a single, consistent surface: directories expand
//// to their `.sql` children in ascii-sorted order, empty
//// directories fail, and errors carry the originating path so
//// callers can render diagnostics.

import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Expand directory entries in `paths` into their `.sql` children.
/// File entries pass through unchanged. `error_fn` maps an
/// offending path and detail string into the caller's error type
/// so each command can attach its own wrapping variant while the
/// underlying diagnostic text stays consistent.
pub fn expand(
  paths: List(String),
  error_fn: fn(String, String) -> error,
) -> Result(List(String), error) {
  paths
  |> list.try_map(fn(path) {
    case simplifile.is_directory(path) {
      Ok(True) ->
        case simplifile.get_files(in: path) {
          Ok(files) -> {
            let sql_files =
              files
              |> list.filter(fn(f) { string.ends_with(f, ".sql") })
              |> list.sort(string.compare)
            case sql_files {
              [] -> Error(error_fn(path, "Directory contains no .sql files"))
              _ -> Ok(sql_files)
            }
          }
          Error(error) ->
            Error(error_fn(
              path,
              "Failed to read directory: " <> simplifile.describe_error(error),
            ))
        }
      Ok(False) -> Ok([path])
      Error(error) ->
        Error(error_fn(
          path,
          "Failed to access path: " <> simplifile.describe_error(error),
        ))
    }
  })
  |> result.map(list.flatten)
}
