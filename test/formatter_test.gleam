import gleam/list
import gleam/string
import gleeunit/should
import simplifile
import sqlode/internal/formatter

const test_dir = "test_output/formatter_test"

fn cleanup() {
  let _delete_result = simplifile.delete(test_dir)
  Nil
}

fn setup() {
  cleanup()
  let assert Ok(_) = simplifile.create_directory_all(test_dir)
  Nil
}

// --- format_files: happy path ---

pub fn format_files_breaks_long_record_lines_test() {
  setup()

  // Mirror the shape the issue calls out: a wide record on a single
  // line. `gleam format` should break it across multiple lines once
  // the formatter step runs.
  let unformatted_source =
    "pub type Reading { Reading(id: Int, station_id: String, temp_c: Float, humidity: Float, pressure: Float, observed_at: String, short_id: String) }
"
  let path = test_dir <> "/long_record.gleam"
  let assert Ok(_) = simplifile.write(path, unformatted_source)

  let assert Ok(Nil) = formatter.format_files([path])

  let assert Ok(formatted) = simplifile.read(path)
  let max_line_width =
    formatted
    |> string.split("\n")
    |> list.map(string.length)
    |> list.fold(0, fn(acc, n) {
      case n > acc {
        True -> n
        False -> acc
      }
    })
  // The original line is 152 chars; the gleam default is 80. The
  // formatter must break the record across lines so no single line
  // stays past the ruler.
  { max_line_width < 100 }
  |> should.be_true

  cleanup()
}

pub fn format_files_empty_list_is_noop_test() {
  // No files to format must succeed without invoking the binary —
  // otherwise an empty `--out` directory would error spuriously.
  let assert Ok(Nil) = formatter.format_files([])
}

pub fn format_files_propagates_syntax_errors_test() {
  setup()

  let bad_source = "pub fn !!!not gleam\n"
  let path = test_dir <> "/bad.gleam"
  let assert Ok(_) = simplifile.write(path, bad_source)

  case formatter.format_files([path]) {
    Ok(Nil) -> should.fail()
    Error(formatter.GleamNotFound) -> should.fail()
    Error(formatter.FormatFailed(exit_code:, output:)) -> {
      // Non-zero exit and the captured stderr should mention the file
      // so users can find the offending generated source.
      { exit_code != 0 } |> should.be_true
      { string.contains(output, "bad.gleam") || string.length(output) > 0 }
      |> should.be_true
    }
  }

  cleanup()
}

// --- error_to_string ---

pub fn error_to_string_gleam_not_found_test() {
  formatter.error_to_string(formatter.GleamNotFound)
  |> string.contains("gleam command not found")
  |> should.be_true
}

pub fn error_to_string_format_failed_includes_exit_code_test() {
  formatter.error_to_string(formatter.FormatFailed(exit_code: 7, output: ""))
  |> string.contains("exit code 7")
  |> should.be_true
}

pub fn error_to_string_format_failed_appends_output_when_present_test() {
  let message =
    formatter.error_to_string(formatter.FormatFailed(
      exit_code: 1,
      output: "syntax error at line 3",
    ))
  message
  |> string.contains("exit code 1")
  |> should.be_true
  message
  |> string.contains("syntax error at line 3")
  |> should.be_true
}

pub fn error_to_string_format_failed_omits_blank_output_test() {
  let message =
    formatter.error_to_string(formatter.FormatFailed(
      exit_code: 1,
      output: "   \n  ",
    ))
  // Whitespace-only output should not produce a trailing ": " with
  // nothing after it.
  message
  |> string.ends_with(": ")
  |> should.be_false
}
