import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

pub fn prepare_no_slices_test() {
  let query =
    runtime.RawQuery(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(_) { [runtime.Int(42)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, values) = runtime.prepare(query, Nil)
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.Int(42)])
}

pub fn prepare_with_slices_test() {
  let query =
    runtime.RawQuery(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)",
      command: runtime.Many,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(ids) { list.map(ids, runtime.Int) },
      slice_info: fn(ids) { [#(1, list.length(ids))] },
    )
  let #(sql, values) = runtime.prepare(query, [10, 20, 30])
  sql |> should.equal("SELECT * FROM users WHERE id IN ($1, $2, $3)")
  values
  |> should.equal([runtime.Int(10), runtime.Int(20), runtime.Int(30)])
}

pub fn prepare_mixed_params_test() {
  let query =
    runtime.RawQuery(
      name: "GetByNameAndIds",
      sql: "SELECT * FROM users WHERE name = __sqlode_param_1__ AND id IN (__sqlode_slice_2__)",
      command: runtime.Many,
      param_count: 2,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(p: #(String, List(Int))) {
        list.flatten([[runtime.String(p.0)], list.map(p.1, runtime.Int)])
      },
      slice_info: fn(p: #(String, List(Int))) { [#(2, list.length(p.1))] },
    )
  let #(sql, values) = runtime.prepare(query, #("Alice", [1, 2]))
  sql
  |> should.equal("SELECT * FROM users WHERE name = $1 AND id IN ($2, $3)")
  values
  |> should.equal([
    runtime.String("Alice"),
    runtime.Int(1),
    runtime.Int(2),
  ])
}

pub fn prepare_mysql_slice_expands_to_positional_test() {
  let query =
    runtime.RawQuery(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)",
      command: runtime.Many,
      param_count: 1,
      placeholder_style: runtime.QuestionPositional,
      encode: fn(ids) { list.map(ids, runtime.Int) },
      slice_info: fn(ids) { [#(1, list.length(ids))] },
    )
  let #(sql, _values) = runtime.prepare(query, [10, 20, 30])
  sql |> should.equal("SELECT * FROM users WHERE id IN (?, ?, ?)")
}

pub fn prepare_mysql_mixed_params_and_slice_test() {
  let query =
    runtime.RawQuery(
      name: "GetByNameAndIds",
      sql: "SELECT * FROM users WHERE name = __sqlode_param_1__ AND id IN (__sqlode_slice_2__) AND status = __sqlode_param_3__",
      command: runtime.Many,
      param_count: 3,
      placeholder_style: runtime.QuestionPositional,
      encode: fn(_) { [] },
      slice_info: fn(_) { [#(2, 2)] },
    )
  let #(sql, _values) = runtime.prepare(query, Nil)
  sql
  |> should.equal(
    "SELECT * FROM users WHERE name = ? AND id IN (?, ?) AND status = ?",
  )
}

pub fn prepare_sqlite_reads_style_from_raw_query_test() {
  let query =
    runtime.RawQuery(
      name: "GetById",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.QuestionNumbered,
      encode: fn(_) { [runtime.Int(1)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, _values) = runtime.prepare(query, Nil)
  sql |> should.equal("SELECT * FROM users WHERE id = ?1")
}

pub fn prepare_preserves_string_literal_with_placeholder_text_test() {
  // Even when a string literal in the SQL looks like a placeholder (`$1`),
  // the marker-based expansion must not touch it.
  let sql =
    "SELECT '$1 is a placeholder' AS note, id FROM t WHERE id = __sqlode_param_1__"
  let result = expand(sql, [], 1, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT '$1 is a placeholder' AS note, id FROM t WHERE id = $1",
  )
}

pub fn prepare_preserves_comment_with_placeholder_text_test() {
  let sql =
    "SELECT id FROM t /* $1 is the placeholder used below */ WHERE id = __sqlode_param_1__"
  let result = expand(sql, [], 1, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT id FROM t /* $1 is the placeholder used below */ WHERE id = $1",
  )
}

pub fn prepare_mysql_with_placeholder_literal_test() {
  // MySQL uses bare `?`. Text like `?` inside a string literal must be
  // preserved even while slice markers are expanded.
  let sql =
    "SELECT '? is a placeholder' AS note, id FROM t WHERE id IN (__sqlode_slice_1__)"
  let result = expand(sql, [#(1, 3)], 1, runtime.QuestionPositional)
  result
  |> should.equal(
    "SELECT '? is a placeholder' AS note, id FROM t WHERE id IN (?, ?, ?)",
  )
}

pub fn prepare_zero_length_collapses_to_null_test() {
  // An empty list becomes NULL so `IN (...)` matches no rows.
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let out = expand(sql, [#(1, 0)], 1, runtime.QuestionPositional)
  out |> should.equal("SELECT * FROM t WHERE id IN (NULL)")
}

pub fn param_marker_accepts_one_test() {
  // Boundary: index 1 is the smallest valid value.
  runtime.param_marker(1) |> should.equal("__sqlode_param_1__")
}

pub fn slice_marker_accepts_one_test() {
  runtime.slice_marker(1) |> should.equal("__sqlode_slice_1__")
}

pub fn param_marker_round_trips_for_index_one_test() {
  let sql = "SELECT * FROM t WHERE id = " <> runtime.param_marker(1)
  let expanded = expand(sql, [], 1, runtime.QuestionNumbered)
  expanded |> should.equal("SELECT * FROM t WHERE id = ?1")
}

pub fn slice_marker_round_trips_for_index_one_test() {
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let expanded = expand(sql, [#(1, 3)], 1, runtime.QuestionNumbered)
  expanded |> should.equal("SELECT * FROM t WHERE id IN (?1, ?2, ?3)")
}

pub fn nullable_encodes_some_and_none_test() {
  runtime.nullable(Some("Ann"), runtime.String)
  |> should.equal(runtime.String("Ann"))
  runtime.nullable(None, runtime.String) |> should.equal(runtime.Null)
}

fn expand(
  sql: String,
  slices: List(#(Int, Int)),
  param_count: Int,
  style: runtime.PlaceholderStyle,
) -> String {
  let query =
    runtime.RawQuery(
      name: "Query",
      sql:,
      command: runtime.Many,
      param_count:,
      placeholder_style: style,
      encode: fn(_) { [] },
      slice_info: fn(_) { slices },
    )
  runtime.prepare(query, Nil).0
}
