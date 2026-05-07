import gleam/list
import gleeunit
import gleeunit/should
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

pub fn null_value_test() {
  runtime.null() |> should.equal(runtime.SqlNull)
}

pub fn string_value_test() {
  runtime.string("hello") |> should.equal(runtime.SqlString("hello"))
}

pub fn int_value_test() {
  runtime.int(42) |> should.equal(runtime.SqlInt(42))
}

pub fn float_value_test() {
  runtime.float(3.14) |> should.equal(runtime.SqlFloat(3.14))
}

pub fn bool_value_test() {
  runtime.bool(True) |> should.equal(runtime.SqlBool(True))
  runtime.bool(False) |> should.equal(runtime.SqlBool(False))
}

pub fn bytes_value_test() {
  runtime.bytes(<<1, 2, 3>>) |> should.equal(runtime.SqlBytes(<<1, 2, 3>>))
}

pub fn array_value_test() {
  runtime.array([runtime.string("a"), runtime.string("b")])
  |> should.equal(
    runtime.SqlArray([runtime.SqlString("a"), runtime.SqlString("b")]),
  )
}

pub fn array_empty_test() {
  runtime.array([])
  |> should.equal(runtime.SqlArray([]))
}

pub fn array_nested_types_test() {
  runtime.array([runtime.int(1), runtime.int(2), runtime.int(3)])
  |> should.equal(
    runtime.SqlArray([
      runtime.SqlInt(1),
      runtime.SqlInt(2),
      runtime.SqlInt(3),
    ]),
  )
}

pub fn prepare_no_slices_test() {
  let query =
    runtime.RawQuery(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.QueryOne,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(_) { [runtime.int(42)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, values) = runtime.prepare(query, Nil)
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.SqlInt(42)])
}

pub fn prepare_with_slices_test() {
  let query =
    runtime.RawQuery(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)",
      command: runtime.QueryMany,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(ids) { list.map(ids, runtime.int) },
      slice_info: fn(ids) { [#(1, list.length(ids))] },
    )
  let #(sql, values) = runtime.prepare(query, [10, 20, 30])
  sql |> should.equal("SELECT * FROM users WHERE id IN ($1, $2, $3)")
  values
  |> should.equal([runtime.SqlInt(10), runtime.SqlInt(20), runtime.SqlInt(30)])
}

pub fn prepare_mixed_params_test() {
  let query =
    runtime.RawQuery(
      name: "GetByNameAndIds",
      sql: "SELECT * FROM users WHERE name = __sqlode_param_1__ AND id IN (__sqlode_slice_2__)",
      command: runtime.QueryMany,
      param_count: 2,
      placeholder_style: runtime.DollarNumbered,
      encode: fn(p: #(String, List(Int))) {
        list.flatten([[runtime.string(p.0)], list.map(p.1, runtime.int)])
      },
      slice_info: fn(p: #(String, List(Int))) { [#(2, list.length(p.1))] },
    )
  let #(sql, values) = runtime.prepare(query, #("Alice", [1, 2]))
  sql
  |> should.equal("SELECT * FROM users WHERE name = $1 AND id IN ($2, $3)")
  values
  |> should.equal([
    runtime.SqlString("Alice"),
    runtime.SqlInt(1),
    runtime.SqlInt(2),
  ])
}

// Regression tests for Issue #360 — marker-based slice expansion

pub fn prepare_mysql_slice_expands_to_positional_test() {
  let query =
    runtime.RawQuery(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)",
      command: runtime.QueryMany,
      param_count: 1,
      placeholder_style: runtime.QuestionPositional,
      encode: fn(ids) { list.map(ids, runtime.int) },
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
      command: runtime.QueryMany,
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

// Issue #359 — placeholder style carried by RawQuery

pub fn prepare_sqlite_reads_style_from_raw_query_test() {
  let query =
    runtime.RawQuery(
      name: "GetById",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.QueryOne,
      param_count: 1,
      placeholder_style: runtime.QuestionNumbered,
      encode: fn(_) { [runtime.int(1)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, _values) = runtime.prepare(query, Nil)
  sql |> should.equal("SELECT * FROM users WHERE id = ?1")
}

pub fn expand_slice_placeholders_preserves_string_literal_with_placeholder_text_test() {
  // Even when a string literal in the SQL looks like a placeholder (`$1`),
  // the marker-based expansion must not touch it.
  let sql =
    "SELECT '$1 is a placeholder' AS note, id FROM t WHERE id = __sqlode_param_1__"
  let result =
    runtime.expand_slice_placeholders(sql, [], 1, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT '$1 is a placeholder' AS note, id FROM t WHERE id = $1",
  )
}

pub fn expand_slice_placeholders_preserves_comment_with_placeholder_text_test() {
  let sql =
    "SELECT id FROM t /* $1 is the placeholder used below */ WHERE id = __sqlode_param_1__"
  let result =
    runtime.expand_slice_placeholders(sql, [], 1, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT id FROM t /* $1 is the placeholder used below */ WHERE id = $1",
  )
}

pub fn expand_slice_placeholders_mysql_with_placeholder_literal_test() {
  // MySQL uses bare `?`. Text like `?` inside a string literal must be
  // preserved even while slice markers are expanded.
  let sql =
    "SELECT '? is a placeholder' AS note, id FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    runtime.expand_slice_placeholders(
      sql,
      [#(1, 3)],
      1,
      runtime.QuestionPositional,
    )
  result
  |> should.equal(
    "SELECT '? is a placeholder' AS note, id FROM t WHERE id IN (?, ?, ?)",
  )
}

// ---------------------------------------------------------------------------
// Validation: malformed slices input must not silently produce broken
// SQL. The panicking variant fails loudly; the `_checked` variant
// surfaces the same condition as a typed error.
// ---------------------------------------------------------------------------

pub fn expand_slice_placeholders_checked_negative_length_returns_error_test() {
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let result =
    runtime.expand_slice_placeholders_checked(
      sql,
      [#(1, -3)],
      1,
      runtime.QuestionPositional,
    )
  result
  |> should.equal(Error(runtime.SliceLengthNegative(index: 1, length: -3)))
}

pub fn expand_slice_placeholders_checked_index_out_of_range_returns_error_test() {
  let sql = "SELECT * FROM t WHERE id = " <> runtime.param_marker(1)
  let result =
    runtime.expand_slice_placeholders_checked(
      sql,
      [#(99, 2)],
      1,
      runtime.QuestionPositional,
    )
  result
  |> should.equal(
    Error(runtime.SliceIndexOutOfRange(index: 99, total_params: 1)),
  )
}

pub fn expand_slice_placeholders_checked_index_zero_returns_error_test() {
  // 1-based indices: zero is out of range too.
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(0) <> ")"
  let result =
    runtime.expand_slice_placeholders_checked(
      sql,
      [#(0, 1)],
      1,
      runtime.QuestionPositional,
    )
  result
  |> should.equal(
    Error(runtime.SliceIndexOutOfRange(index: 0, total_params: 1)),
  )
}

pub fn expand_slice_placeholders_checked_zero_length_collapses_to_null_test() {
  // Length 0 is a legitimate degenerate case: expands to NULL so that
  // `WHERE x IN (NULL)` evaluates to NULL (always-false). Validate this
  // continues to work via the checked path.
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let result =
    runtime.expand_slice_placeholders_checked(
      sql,
      [#(1, 0)],
      1,
      runtime.QuestionPositional,
    )
  result
  |> should.equal(Ok("SELECT * FROM t WHERE id IN (NULL)"))
}

pub fn expand_slice_placeholders_checked_valid_slices_match_panicking_variant_test() {
  // For valid input the checked variant must produce byte-identical
  // output to the panicking variant.
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let panicking =
    runtime.expand_slice_placeholders(
      sql,
      [#(1, 3)],
      1,
      runtime.QuestionPositional,
    )
  let checked =
    runtime.expand_slice_placeholders_checked(
      sql,
      [#(1, 3)],
      1,
      runtime.QuestionPositional,
    )
  checked |> should.equal(Ok(panicking))
}
