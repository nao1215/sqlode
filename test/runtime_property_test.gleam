//// Worked examples of `runtime.raw_query` in use. Custom-adapter
//// authors and property-test authors can lift the patterns here directly.
////
//// The helper is identical to invoking the `RawQuery(...)` constructor;
//// it exists to make the intent ("hand-rolled RawQuery, not codegen
//// output") obvious at the call site. Production code should always use
//// codegen-emitted `RawQuery` values.

import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import metamon
import metamon/generator
import metamon/generator/range
import sqlode/runtime

// ---------------------------------------------------------------------------
// Example 1 — minimal RawQuery for a single-parameter SELECT, run through
// `prepare` to obtain the final SQL and value list.
// ---------------------------------------------------------------------------

pub fn raw_query_minimal_prepare_test() {
  let query =
    runtime.raw_query(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = " <> runtime.param_marker(1),
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(id) { [runtime.int(id)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, values) = runtime.prepare(query, 42)
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.Int(42)])
}

// ---------------------------------------------------------------------------
// Example 2 — RawQuery exercising slice expansion across the three
// placeholder styles. Demonstrates the equivariance the runtime
// guarantees: same slice metadata, three different on-the-wire shapes.
// ---------------------------------------------------------------------------

pub fn raw_query_across_placeholder_styles_test() {
  let make_query = fn(style) {
    runtime.raw_query(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (" <> runtime.slice_marker(1) <> ")",
      command: runtime.Many,
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

pub fn raw_query_zero_length_slice_collapses_to_null_test() {
  let query =
    runtime.raw_query(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (" <> runtime.slice_marker(1) <> ")",
      command: runtime.Many,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(_) { [] },
      slice_info: fn(_) { [#(1, 0)] },
    )
  let #(sql, values) = runtime.prepare(query, [])
  sql |> should.equal("SELECT * FROM users WHERE id IN (NULL)")
  values |> should.equal([])
}

// ---------------------------------------------------------------------------
// expand_slice_placeholders replaces markers in one pass. It must give
// the same SQL as replacing each marker in turn, including around text
// that only looks like a marker.
// ---------------------------------------------------------------------------

fn indices(from: Int, to: Int) -> List(Int) {
  int.range(from:, to: to + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

fn sequential_expand(
  sql: String,
  slices: List(#(Int, Int)),
  total: Int,
) -> String {
  let #(_, replacements) =
    list.fold(indices(1, total), #(1, []), fn(acc, index) {
      let #(next, out) = acc
      case list.key_find(slices, index) {
        Ok(0) -> #(next, [#(runtime.slice_marker(index), "NULL"), ..out])
        Ok(length) -> #(next + length, [
          #(
            runtime.slice_marker(index),
            indices(next, next + length - 1)
              |> list.map(fn(i) { "$" <> int.to_string(i) })
              |> string.join(", "),
          ),
          ..out
        ])
        Error(Nil) -> #(next + 1, [
          #(runtime.param_marker(index), "$" <> int.to_string(next)),
          ..out
        ])
      }
    })
  list.fold(list.reverse(replacements), sql, fn(s, entry) {
    string.replace(s, entry.0, entry.1)
  })
}

pub fn one_pass_expansion_matches_sequential_replace_test() {
  let fragment =
    generator.element_of([
      "SELECT ",
      "x",
      "_",
      "__",
      "__sqlode_",
      "__sqlode_param_",
      "__sqlode_slice_",
      runtime.param_marker(1),
      runtime.param_marker(2),
      runtime.param_marker(3),
      runtime.slice_marker(2),
      runtime.param_marker(12),
      "__sqlode_param_01__",
      "__sqlode_param_x__",
      "'$1'",
    ])
  metamon.forall(
    generator.tuple2(
      generator.list_of(fragment, range.constant(0, 12)),
      generator.int(range.constant(0, 3)),
    ),
    fn(input) {
      let #(fragments, slice_length) = input
      let sql = string.concat(fragments)
      let slices = [#(2, slice_length)]
      runtime.expand_slice_placeholders(sql, slices, 3, runtime.DollarNumbered)
      == sequential_expand(sql, slices, 3)
    },
  )
}
