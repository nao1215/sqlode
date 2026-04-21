//// Minimal runnable example for sqlode + SQLite.
////
//// Before building this project, generate the typed Gleam wrappers:
////
////   sqlode generate --config=sqlode.yaml
////
//// The command writes `src/db/{params,models,queries,sqlight_adapter}.gleam`.
//// With those modules in place, `gleam test` runs the end-to-end flow from
//// `test/sqlite_basic_test.gleam`.
////
//// See `doc/tutorials/getting-started-sqlite.md` in the sqlode repository
//// for the full walkthrough.

import gleam/io

pub fn main() {
  io.println(
    "sqlite-basic example. Run `sqlode generate` to produce src/db/*, then `gleam test`.",
  )
}
