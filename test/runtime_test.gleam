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
