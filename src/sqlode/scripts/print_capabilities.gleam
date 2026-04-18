//// Entry point for regenerating `doc/capabilities.md`.
////
//// Run with:
////
////   just regen-capabilities
////
//// or directly:
////
////   gleam run -m sqlode/scripts/print_capabilities > doc/capabilities.md
////
//// The output is exactly what `test/capabilities_test.gleam` pins against
//// the tracked file.

import gleam/io
import sqlode/capabilities

pub fn main() -> Nil {
  io.print(capabilities.manifest_markdown())
}
