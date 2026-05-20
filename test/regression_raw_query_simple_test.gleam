//// Regression tests for Issue #584 — `runtime.raw_query_simple/6`.
////
//// `raw_query_simple` is a thin wrapper around `raw_query/7` that
//// supplies `slice_info: fn(_) { [] }` so hand-rolled queries without
//// slice-expanded `IN ($N)` placeholders do not have to repeat the
//// always-empty lambda. These tests pin the wrapper-equivalence
//// contract: a value constructed via `raw_query_simple` must be
//// indistinguishable from one constructed via `raw_query` with the
//// empty `slice_info`.

import gleeunit
import gleeunit/should
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

// Encode helpers used by multiple cases — kept top-level so the
// equivalence test below can pass the *same* function reference to
// both `raw_query` and `raw_query_simple`.
fn encode_audit(p: #(String, String, String, Int)) -> List(runtime.Value) {
  [
    runtime.string(p.0),
    runtime.string(p.1),
    runtime.string(p.2),
    runtime.int(p.3),
  ]
}

fn encode_id(id: Int) -> List(runtime.Value) {
  [runtime.int(id)]
}

pub fn raw_query_simple_matches_raw_query_with_empty_slice_info_test() {
  let audit_sql =
    "INSERT INTO audit (id, actor, action, amount_minor) VALUES (__sqlode_param_1__, __sqlode_param_2__, __sqlode_param_3__, __sqlode_param_4__)"
  let simple =
    runtime.raw_query_simple(
      name: "insert_audit_row",
      sql: audit_sql,
      command: runtime.Exec,
      param_count: 4,
      placeholder_style: runtime.DollarNumbered,
      encode: encode_audit,
    )
  let full =
    runtime.raw_query(
      name: "insert_audit_row",
      sql: audit_sql,
      command: runtime.Exec,
      param_count: 4,
      placeholder_style: runtime.DollarNumbered,
      encode: encode_audit,
      slice_info: fn(_) { [] },
    )

  // Field-by-field equivalence — function-typed fields (`encode`,
  // `slice_info`) are compared by identity / behaviour rather than by
  // structural equality.
  simple.name |> should.equal(full.name)
  simple.sql |> should.equal(full.sql)
  simple.command |> should.equal(full.command)
  simple.param_count |> should.equal(full.param_count)
  simple.placeholder_style |> should.equal(full.placeholder_style)

  let params = #("a-id", "alice", "create", 100)
  simple.encode(params) |> should.equal(full.encode(params))
  simple.slice_info(params) |> should.equal(full.slice_info(params))
}

pub fn raw_query_simple_prepare_renders_dollar_numbered_test() {
  let query =
    runtime.raw_query_simple(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: encode_id,
    )
  let #(sql, values) = runtime.prepare(query, 42)
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.Int(42)])
}

pub fn raw_query_simple_prepare_respects_question_positional_test() {
  let query =
    runtime.raw_query_simple(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.QuestionPositional,
      encode: encode_id,
    )
  let #(sql, _values) = runtime.prepare(query, 7)
  sql |> should.equal("SELECT * FROM users WHERE id = ?")
}

pub fn raw_query_simple_slice_info_always_empty_test() {
  let query =
    runtime.raw_query_simple(
      name: "GetUser",
      sql: "SELECT * FROM users WHERE id = __sqlode_param_1__",
      command: runtime.One,
      param_count: 1,
      placeholder_style: runtime.DollarNumbered,
      encode: encode_id,
    )
  query.slice_info(1) |> should.equal([])
  query.slice_info(99) |> should.equal([])
}
