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
      sql: "SELECT * FROM users WHERE id = $1",
      command: runtime.QueryOne,
      param_count: 1,
      encode: fn(_) { [runtime.int(42)] },
      slice_info: fn(_) { [] },
    )
  let #(sql, values) = runtime.prepare(query, Nil, "$")
  sql |> should.equal("SELECT * FROM users WHERE id = $1")
  values |> should.equal([runtime.SqlInt(42)])
}

pub fn prepare_with_slices_test() {
  let query =
    runtime.RawQuery(
      name: "GetByIds",
      sql: "SELECT * FROM users WHERE id IN ($1)",
      command: runtime.QueryMany,
      param_count: 1,
      encode: fn(ids) { list.map(ids, runtime.int) },
      slice_info: fn(ids) { [#(1, list.length(ids))] },
    )
  let #(sql, values) = runtime.prepare(query, [10, 20, 30], "$")
  sql |> should.equal("SELECT * FROM users WHERE id IN ($1, $2, $3)")
  values
  |> should.equal([runtime.SqlInt(10), runtime.SqlInt(20), runtime.SqlInt(30)])
}

pub fn prepare_mixed_params_test() {
  let query =
    runtime.RawQuery(
      name: "GetByNameAndIds",
      sql: "SELECT * FROM users WHERE name = $1 AND id IN ($2)",
      command: runtime.QueryMany,
      param_count: 2,
      encode: fn(p: #(String, List(Int))) {
        list.flatten([
          [runtime.string(p.0)],
          list.map(p.1, runtime.int),
        ])
      },
      slice_info: fn(p: #(String, List(Int))) { [#(2, list.length(p.1))] },
    )
  let #(sql, values) = runtime.prepare(query, #("Alice", [1, 2]), "$")
  sql
  |> should.equal("SELECT * FROM users WHERE name = $1 AND id IN ($2, $3)")
  values
  |> should.equal([
    runtime.SqlString("Alice"),
    runtime.SqlInt(1),
    runtime.SqlInt(2),
  ])
}
