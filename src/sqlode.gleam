import argv
import gleam/io
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
  // (#465)
  case glint.execute(cli.app(), argv.load().arguments) {
    Error(message) -> {
      io.println_error(message)
      exit(1)
    }
    Ok(glint.Help(text)) -> io.println(text)
    Ok(glint.Out(_)) -> Nil
  }
}

@external(erlang, "init", "stop")
fn exit(status: Int) -> Nil
