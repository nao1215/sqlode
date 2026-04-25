import argv
import gleam/io
import gleam/string
import glint
import sqlode/cli

pub fn main() -> Nil {
  // glint.run prints both error diagnostics and explicitly-requested
  // help text via stdout. POSIX/CLIG convention is the opposite —
  // diagnostics belong on stderr; only requested output goes to
  // stdout. Drive the dispatch ourselves so that:
  //
  //   * `Error(message)` (unknown flag, no args, etc.) → stderr,
  //     exit 1.
  //   * `Ok(Help(text))` (an explicit `--help` invocation) → stdout
  //     unchanged. The help text is the requested output here.
  //   * `Ok(Out(_))` → command ran; per-command side effects
  //     already wrote whatever they needed to.
  //
  // For the error path we additionally rewrite glint's generic
  // `command not found` diagnostic into a class-specific message
  // (`unrecognized option '--xyz'`, `missing subcommand`, etc.) so
  // the user sees the actual failure mode instead of a misleading
  // `127`-style "binary not found" reading. (#465, #466)
  let args = argv.load().arguments
  case glint.execute(cli.app(), args) {
    Error(message) -> {
      io.println_error(rewrite_error(args, message))
      exit(1)
    }
    Ok(glint.Help(text)) -> io.println(text)
    Ok(glint.Out(_)) -> Nil
  }
}

/// Replace glint's generic `command not found` snag with a
/// class-specific diagnostic that names the actual failure mode.
/// Pure so the test suite can pin every branch without spawning
/// the binary. (#466)
@internal
pub fn rewrite_error(args: List(String), original: String) -> String {
  case string.contains(original, "command not found") {
    True -> classify_invocation(args)
    False -> original
  }
}

fn classify_invocation(args: List(String)) -> String {
  case args {
    [] ->
      "error: missing subcommand. Run 'sqlode --help' to see available commands."
    [first, ..] ->
      case string.starts_with(first, "-") {
        True ->
          "error: unrecognized option '"
          <> first
          <> "'. Run 'sqlode --help' to see available options."
        False ->
          "error: unknown subcommand '"
          <> first
          <> "'. Run 'sqlode --help' to see available commands."
      }
  }
}

@external(erlang, "init", "stop")
fn exit(status: Int) -> Nil
