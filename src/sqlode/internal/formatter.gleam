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
import gleam/string

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
  }
}

@target(erlang)
@external(erlang, "sqlode_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)

@target(erlang)
@external(erlang, "sqlode_ffi", "run_executable")
fn run_executable(executable: String, args: List(String)) -> #(Int, String)
