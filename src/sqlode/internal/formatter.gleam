//// Run `gleam format` on generated source files.
////
//// `sqlode generate` writes Gleam files whose contents are emitted as
//// long, single-line records / decoder chains. The compiled output is
//// correct but is hard to review (a single record line can exceed
//// 200 chars). Running `gleam format` on the written files restores
//// the project-standard line width and matches what the sibling
//// `oaspec` generator already does at the end of its codegen run.
////
//// The CLI is BEAM-only by design (escript), so this module's only
//// real implementation lives behind Erlang FFI. The JavaScript
//// target carries a no-op so `gleam build --target javascript`
//// stays green — the JS lane never invokes `sqlode generate`.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Errors from formatting operations.
pub type FormatError {
  /// `gleam` was not found on `PATH`. The user has installed sqlode
  /// but not the Gleam toolchain — surface an actionable message
  /// instead of a generic exec failure.
  GleamNotFound
  /// `gleam format` ran but exited non-zero. `output` carries the
  /// captured stdout+stderr so a syntax error in the generated file
  /// is visible without re-running by hand.
  FormatFailed(exit_code: Int, output: String)
  /// The temporary copies that `format_sources` formats could not be
  /// written or read back.
  TempDirFailed(path: String, detail: String)
}

@target(erlang)
/// Format the given files in place by invoking `gleam format <files>`.
/// Files (rather than directories) are passed so neighbouring source
/// in the user's project that sqlode did not generate is left
/// untouched.
pub fn format_files(files: List(String)) -> Result(Nil, FormatError) {
  case files {
    [] -> Ok(Nil)
    _ ->
      case find_executable("gleam") {
        Error(Nil) -> Error(GleamNotFound)
        Ok(gleam_path) -> {
          let #(exit_code, output) =
            run_executable(gleam_path, ["format", ..files])
          case exit_code {
            0 -> Ok(Nil)
            code -> Error(FormatFailed(exit_code: code, output: output))
          }
        }
      }
  }
}

@target(javascript)
pub fn format_files(_files: List(String)) -> Result(Nil, FormatError) {
  Ok(Nil)
}

/// Return each source as `gleam format` would leave it, in order,
/// without touching the files they came from. The sources are written
/// to a temporary directory, formatted there in one `gleam format`
/// run, and read back; the directory is removed either way.
pub fn format_sources(
  sources: List(String),
) -> Result(List(String), FormatError) {
  case sources {
    [] -> Ok([])
    _ -> {
      let dir = unique_temp_path()
      let paths =
        list.index_map(sources, fn(_source, index) {
          dir <> "/source_" <> int.to_string(index) <> ".gleam"
        })
      let formatted = {
        use _ <- result.try(
          simplifile.create_directory_all(dir)
          |> result.map_error(temp_dir_error(dir, _)),
        )
        use _ <- result.try(
          list.zip(paths, sources)
          |> list.try_each(fn(pair) { simplifile.write(pair.0, pair.1) })
          |> result.map_error(temp_dir_error(dir, _)),
        )
        use _ <- result.try(format_files(paths))
        list.try_map(paths, simplifile.read)
        |> result.map_error(temp_dir_error(dir, _))
      }
      let _delete_result = simplifile.delete(dir)
      formatted
    }
  }
}

fn temp_dir_error(dir: String, error: simplifile.FileError) -> FormatError {
  TempDirFailed(path: dir, detail: simplifile.describe_error(error))
}

/// Convert a format error to a human-readable string for CLI output.
pub fn error_to_string(error: FormatError) -> String {
  case error {
    GleamNotFound ->
      "gleam command not found in PATH. Install Gleam to format generated code."
    FormatFailed(code, output) -> {
      let trimmed = string.trim(output)
      case trimmed {
        "" -> "gleam format failed with exit code " <> int.to_string(code)
        _ ->
          "gleam format failed with exit code "
          <> int.to_string(code)
          <> ": "
          <> trimmed
      }
    }
    TempDirFailed(path:, detail:) ->
      "could not format a copy of the generated code in "
      <> path
      <> ": "
      <> detail
  }
}

@target(erlang)
@external(erlang, "sqlode_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)

@target(erlang)
@external(erlang, "sqlode_ffi", "run_executable")
fn run_executable(executable: String, args: List(String)) -> #(Int, String)

@target(erlang)
@external(erlang, "sqlode_ffi", "unique_temp_path")
fn unique_temp_path() -> String

// The CLI does not run on JavaScript. `format_files` is a no-op there,
// so `format_sources` round-trips the sources through this directory
// unchanged.
@target(javascript)
fn unique_temp_path() -> String {
  "sqlode-format"
}
