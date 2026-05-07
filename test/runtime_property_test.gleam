//// Worked examples of `runtime.raw_query_for_test` in use. Custom-adapter
//// authors and property-test authors can lift the patterns here directly.
////
//// The helper is identical to invoking the `RawQuery(...)` constructor;
//// it exists to make the intent ("hand-rolled RawQuery, not codegen
//// output") obvious at the call site. Production code should always use
//// codegen-emitted `RawQuery` values.

import gleam/list
import gleeunit/should
import sqlode/runtime

// ---------------------------------------------------------------------------
// Example 1 — minimal RawQuery for a single-parameter SELECT, run through
// `prepare` to obtain the final SQL and value list.
// ---------------------------------------------------------------------------

pub fn raw_query_for_test_minimal_prepare_test() {
  let query =
    runtime.raw_query_for_test(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = " <> runtime.param_marker(1),
      command: runtime.QueryOne,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(id) { [runtime.int(id)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, values) = runtime.prepare(query, 42)
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.SqlInt(42)])
}

// ---------------------------------------------------------------------------
// Example 2 — RawQuery exercising slice expansion across the three
// placeholder styles. Demonstrates the equivariance the runtime
// guarantees: same slice metadata, three different on-the-wire shapes.
// ---------------------------------------------------------------------------

pub fn raw_query_for_test_across_placeholder_styles_test() {
  let make_query = fn(style) {
    runtime.raw_query_for_test(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (" <> runtime.slice_marker(1) <> ")",
      command: runtime.QueryMany,
      param_count: 1,
      placeholder_style: style,
      encode: fn(ids) { list.map(ids, runtime.int) },
      slice_info: fn(ids) { [#(1, list.length(ids))] },
    )
  }

  let #(sql_pg, _) =
    runtime.prepare(make_query(runtime.DollarNumbered), [10, 20])
  sql_pg |> should.equal("SELECT * FROM users WHERE id IN ($1, $2)")

  let #(sql_sqlite, _) =
    runtime.prepare(make_query(runtime.QuestionNumbered), [10, 20])
  sql_sqlite |> should.equal("SELECT * FROM users WHERE id IN (?1, ?2)")

  let #(sql_mysql, _) =
    runtime.prepare(make_query(runtime.QuestionPositional), [10, 20])
  sql_mysql |> should.equal("SELECT * FROM users WHERE id IN (?, ?)")
}

// ---------------------------------------------------------------------------
// Example 3 — RawQuery with a zero-length slice, exercising the
// `IN (NULL)` rewrite without going through the codegen pipeline.
// ---------------------------------------------------------------------------

pub fn raw_query_for_test_zero_length_slice_collapses_to_null_test() {
  let query =
    runtime.raw_query_for_test(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (" <> runtime.slice_marker(1) <> ")",
      command: runtime.QueryMany,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(_) { [] },
      slice_info: fn(_) { [#(1, 0)] },
    )
  let #(sql, values) = runtime.prepare(query, [])
  sql |> should.equal("SELECT * FROM users WHERE id IN (NULL)")
  values |> should.equal([])
}
