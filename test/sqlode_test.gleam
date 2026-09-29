//// Entry point for `gleam test`. gleeunit discovers the `*_test`
//// functions in every module under `test/`, so tests live in their own
//// modules and are not listed here.

import gleeunit

pub fn main() {
  gleeunit.main()
}
