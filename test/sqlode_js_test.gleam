//// JavaScript-target test entry point for `sqlode/runtime`.
////
//// The default `gleam test --target javascript` lane fails on this
//// repository because `gleeunit`'s JavaScript runner auto-discovers
//// every `*_test.mjs` file under `build/dev/javascript/sqlode/test/`
//// and `cli_test.mjs` transitively pulls in `glint.mjs`, whose
//// generated JavaScript currently fails to parse on Node
//// (`SyntaxError: Identifier '$2' has already been declared` near
//// `let $2 = $list.partition(...)` — a known compiler-emitted code
//// shape on this glint version). The CLI is BEAM-only by design
//// (escript), so the failure is in dependency wiring, not in
//// `sqlode/runtime` semantics.
////
//// To still gate releases on the cross-target runtime contract, this
//// module is a hand-rolled JavaScript-only test entry that calls
//// every `runtime_test` function explicitly. It bypasses gleeunit's
//// auto-discovery and therefore loads only `runtime_test`,
//// `sqlode/runtime`, and `gleeunit/should` at run time — none of
//// which depend on `glint`. The same `runtime_test` functions still
//// run on Erlang under the standard `gleam test` lane.
////
//// Run locally:
////   gleam run -m sqlode_js_test --target javascript
////
//// Add new entries here whenever a new `runtime_test` function lands
//// so the JavaScript lane keeps full parity with the Erlang lane for
//// the runtime surface generated code calls into.

import gleam/io
import runtime_test

pub fn main() {
  io.println("=== sqlode/runtime laws on the JavaScript target ===")

  // --- Value encoders -----------------------------------------------------
  runtime_test.null_value_test()
  runtime_test.string_value_test()
  runtime_test.int_value_test()
  runtime_test.float_value_test()
  runtime_test.bool_value_test()
  runtime_test.bytes_value_test()
  runtime_test.array_value_test()
  runtime_test.array_empty_test()
  runtime_test.array_nested_types_test()

  // --- prepare(): placeholder + slice expansion ---------------------------
  runtime_test.prepare_no_slices_test()
  runtime_test.prepare_with_slices_test()
  runtime_test.prepare_mixed_params_test()
  runtime_test.prepare_mysql_slice_expands_to_positional_test()
  runtime_test.prepare_mysql_mixed_params_and_slice_test()
  runtime_test.prepare_sqlite_reads_style_from_raw_query_test()

  // --- expand_slice_placeholders edge cases -------------------------------
  runtime_test.expand_slice_placeholders_preserves_string_literal_with_placeholder_text_test()
  runtime_test.expand_slice_placeholders_preserves_comment_with_placeholder_text_test()
  runtime_test.expand_slice_placeholders_mysql_with_placeholder_literal_test()

  io.println("All 18 runtime laws passed on the JavaScript target.")
}
