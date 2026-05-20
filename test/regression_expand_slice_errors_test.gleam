import gleeunit/should
import sqlode/runtime as sql

// Pin the post-#585 ExpandError refinement: each distinct failure mode
// of `expand_slice_placeholders_checked` now surfaces as its own
// variant instead of the legacy `SliceIndexOutOfRange(0, 0)` umbrella.

pub fn empty_slice_reports_empty_slice_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(1, 0)],
      0,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.EmptySlice(at_placeholder: 1)) -> Nil
    _ -> should.fail()
  }
}

pub fn empty_slice_at_arbitrary_index_reports_empty_slice_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(2, 0)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.EmptySlice(at_placeholder: 2)) -> Nil
    _ -> should.fail()
  }
}

pub fn slice_start_zero_reports_non_positive_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(0, 3)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.SliceStartNonPositive(start: 0)) -> Nil
    _ -> should.fail()
  }
}

pub fn slice_start_negative_reports_non_positive_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(-1, 2)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.SliceStartNonPositive(start: -1)) -> Nil
    _ -> should.fail()
  }
}

pub fn slice_start_after_params_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(5, 1)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.SliceStartAfterParams(start: 5, total: 3)) -> Nil
    _ -> should.fail()
  }
}

pub fn slice_length_exceeds_params_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(1, 5)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.SliceLengthExceedsParams(start: 1, length: 5, total: 3)) -> Nil
    _ -> should.fail()
  }
}

pub fn slice_length_negative_still_reports_length_negative_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let result =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(1, -2)],
      3,
      sql.DollarNumbered,
    )
  case result {
    Error(sql.SliceLengthNegative(index: 1, length: -2)) -> Nil
    _ -> should.fail()
  }
}

pub fn no_slice_no_placeholder_returns_sql_unchanged_test() {
  let assert Ok(s) =
    sql.expand_slice_placeholders_checked("SELECT 1", [], 0, sql.DollarNumbered)
  s |> should.equal("SELECT 1")
}

pub fn normal_slice_expansion_test() {
  let sql_str = "SELECT * FROM t WHERE id IN (__sqlode_slice_1__)"
  let assert Ok(out) =
    sql.expand_slice_placeholders_checked(
      sql_str,
      [#(1, 3)],
      3,
      sql.DollarNumbered,
    )
  out
  |> should.equal("SELECT * FROM t WHERE id IN ($1, $2, $3)")
}
