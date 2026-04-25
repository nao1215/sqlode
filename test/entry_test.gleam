//// Tests for the top-level `sqlode.main` error-rewriting helper.
////
//// `glint.execute` returns a generic snag-formatted message
//// (`"failed to run command\n  cause:\n    command not found\n..."`)
//// for unknown flags, missing subcommands, and unknown subcommands
//// alike. `sqlode.rewrite_error` classifies those cases and returns
//// a class-specific message; this file pins the classification so a
//// regression that broadens or narrows a branch fails loudly. (#466)

import gleam/string
import gleeunit/should
import sqlode

const glint_command_not_found = "error: failed to run command

cause:
  0: command not found

See the following help text, available via the '--help' flag.
"

pub fn rewrite_error_no_args_says_missing_subcommand_test() {
  let result = sqlode.rewrite_error([], glint_command_not_found)
  result
  |> string.contains("missing subcommand")
  |> should.be_true
}

pub fn rewrite_error_long_flag_says_unrecognized_option_test() {
  let result = sqlode.rewrite_error(["--xyz"], glint_command_not_found)
  result
  |> string.contains("unrecognized option '--xyz'")
  |> should.be_true
}

pub fn rewrite_error_short_flag_says_unrecognized_option_test() {
  let result = sqlode.rewrite_error(["-h"], glint_command_not_found)
  result
  |> string.contains("unrecognized option '-h'")
  |> should.be_true
}

pub fn rewrite_error_version_flag_says_unrecognized_option_test() {
  // The headline #466 case: `--version` is a flag, not a command.
  // The previous wording "command not found" was misleading.
  let result = sqlode.rewrite_error(["--version"], glint_command_not_found)
  result
  |> string.contains("unrecognized option '--version'")
  |> should.be_true
}

pub fn rewrite_error_unknown_subcommand_says_unknown_subcommand_test() {
  let result = sqlode.rewrite_error(["foo"], glint_command_not_found)
  result
  |> string.contains("unknown subcommand 'foo'")
  |> should.be_true
}

pub fn rewrite_error_passes_through_unrelated_messages_test() {
  // Errors that did NOT originate from glint's "command not found"
  // path must reach the user verbatim — sqlode does not own their
  // wording (e.g. config-load failures, generate-time errors).
  let original = "error: config file not found at /tmp/missing.yaml"
  sqlode.rewrite_error(["generate"], original)
  |> should.equal(original)
}

pub fn rewrite_error_no_args_does_not_call_unrecognized_option_test() {
  // Negative form: empty args must NOT produce the flag wording.
  sqlode.rewrite_error([], glint_command_not_found)
  |> string.contains("unrecognized option")
  |> should.be_false
}
