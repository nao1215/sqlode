import gleam/list
import gleeunit
import gleeunit/should
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

pub fn null_value_test() {
  runtime.null() |> should.equal(runtime.Null)
}

pub fn string_value_test() {
  runtime.string("hello") |> should.equal(runtime.String("hello"))
}

pub fn int_value_test() {
  runtime.int(42) |> should.equal(runtime.Int(42))
}

pub fn float_value_test() {
  runtime.float(3.14) |> should.equal(runtime.Float(3.14))
}

pub fn bool_value_test() {
  runtime.bool(True) |> should.equal(runtime.Bool(True))
  runtime.bool(False) |> should.equal(runtime.Bool(False))
}

pub fn bytes_value_test() {
  runtime.bytes(<<1, 2, 3>>) |> should.equal(runtime.Bytes(<<1, 2, 3>>))
}

pub fn array_value_test() {
  runtime.array([runtime.string("a"), runtime.string("b")])
  |> should.equal(runtime.Array([runtime.String("a"), runtime.String("b")]))
}

pub fn array_empty_test() {
  runtime.array([])
  |> should.equal(runtime.Array([]))
}

pub fn array_nested_types_test() {
  runtime.array([runtime.int(1), runtime.int(2), runtime.int(3)])
  |> should.equal(
    runtime.Array([
      runtime.Int(1),
      runtime.Int(2),
      runtime.Int(3),
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
  values |> should.equal([runtime.Int(42)])
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
  |> should.equal([runtime.Int(10), runtime.Int(20), runtime.Int(30)])
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
    runtime.String("Alice"),
    runtime.Int(1),
    runtime.Int(2),
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
  // 1-based indices: zero is out of range too. The marker constructor
  // now panics on index < 1 (#551), so we hand-roll the marker literal
  // here to exercise the validator surface — that is what would happen
  // if a buggy adapter put `0` in the slices list while still emitting
  // a valid 1-based marker in the SQL.
  let sql = "SELECT * FROM t WHERE id IN (__sqlode_slice_0__)"
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

pub fn expand_slice_placeholders_checked_negative_total_params_returns_error_test() {
  // Issue #565: total_params < 0 must surface as Error rather than
  // panicking through the int.range loop inside
  // expand_slice_placeholders (which calls param_marker(0), banned
  // post-#551). The `_checked` variant's promise is "no panic on
  // user input"; this pins the boundary at total_params = -2 from
  // the reproduction.
  let result =
    runtime.expand_slice_placeholders_checked(
      "",
      [],
      -2,
      runtime.QuestionNumbered,
    )
  result
  |> should.equal(Error(runtime.TotalParamsNegative(total_params: -2)))
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

// ---------------------------------------------------------------------------
// param_marker / slice_marker reject non-1-based indices (#551).
// The runtime expand step is keyed by 1-based positions; a `0` or
// negative index would either round-trip to a syntactically broken SQL
// string (the literal marker stays in place) or silently match an
// unrelated marker (silent SQL-shape bug). The checked variants surface
// the precondition as a `Result`; the panicking variants are exercised
// indirectly through the codegen path which always emits 1-based
// indices.
// ---------------------------------------------------------------------------

pub fn param_marker_accepts_one_test() {
  // Boundary: index 1 is the smallest valid value.
  runtime.param_marker(1) |> should.equal("__sqlode_param_1__")
}

pub fn slice_marker_accepts_one_test() {
  runtime.slice_marker(1) |> should.equal("__sqlode_slice_1__")
}

pub fn param_marker_accepts_large_index_test() {
  runtime.param_marker(99_999) |> should.equal("__sqlode_param_99999__")
}

pub fn slice_marker_accepts_large_index_test() {
  runtime.slice_marker(99_999) |> should.equal("__sqlode_slice_99999__")
}

// --- _checked variants ---

pub fn param_marker_checked_returns_error_for_zero_test() {
  runtime.param_marker_checked(0)
  |> should.equal(Error(runtime.MarkerIndexNonPositive(index: 0)))
}

pub fn param_marker_checked_returns_error_for_negative_test() {
  runtime.param_marker_checked(-7)
  |> should.equal(Error(runtime.MarkerIndexNonPositive(index: -7)))
}

pub fn slice_marker_checked_returns_error_for_zero_test() {
  runtime.slice_marker_checked(0)
  |> should.equal(Error(runtime.MarkerIndexNonPositive(index: 0)))
}

pub fn slice_marker_checked_returns_error_for_negative_test() {
  runtime.slice_marker_checked(-42)
  |> should.equal(Error(runtime.MarkerIndexNonPositive(index: -42)))
}

pub fn param_marker_checked_matches_panicking_variant_for_valid_indices_test() {
  // For valid input the checked variant must produce byte-identical
  // output to the panicking variant. Same invariant the equivalent
  // expand_slice_placeholders_checked test pins.
  runtime.param_marker_checked(1) |> should.equal(Ok(runtime.param_marker(1)))
  runtime.param_marker_checked(5) |> should.equal(Ok(runtime.param_marker(5)))
}

pub fn slice_marker_checked_matches_panicking_variant_for_valid_indices_test() {
  runtime.slice_marker_checked(1) |> should.equal(Ok(runtime.slice_marker(1)))
  runtime.slice_marker_checked(9) |> should.equal(Ok(runtime.slice_marker(9)))
}

// --- Marker round-trips through expand_slice_placeholders for valid indices ---

pub fn param_marker_round_trips_for_index_one_test() {
  let sql = "SELECT * FROM t WHERE id = " <> runtime.param_marker(1)
  let expanded =
    runtime.expand_slice_placeholders(sql, [], 1, runtime.QuestionNumbered)
  expanded |> should.equal("SELECT * FROM t WHERE id = ?1")
}

pub fn slice_marker_round_trips_for_index_one_test() {
  let sql = "SELECT * FROM t WHERE id IN (" <> runtime.slice_marker(1) <> ")"
  let expanded =
    runtime.expand_slice_placeholders(
      sql,
      [#(1, 3)],
      1,
      runtime.QuestionNumbered,
    )
  expanded |> should.equal("SELECT * FROM t WHERE id IN (?1, ?2, ?3)")
}
