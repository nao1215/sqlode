import gleeunit
import gleeunit/should
import sqlode/model

pub fn main() {
  gleeunit.main()
}

// parse_engine tests

pub fn parse_engine_postgresql_test() {
  model.parse_engine("postgresql") |> should.equal(Ok(model.PostgreSQL))
}

pub fn parse_engine_mysql_test() {
  model.parse_engine("mysql") |> should.equal(Ok(model.MySQL))
}

pub fn parse_engine_sqlite_test() {
  model.parse_engine("sqlite") |> should.equal(Ok(model.SQLite))
}

pub fn parse_engine_invalid_test() {
  model.parse_engine("oracle") |> should.be_error()
}

// parse_runtime tests

pub fn parse_runtime_raw_test() {
  model.parse_runtime("raw") |> should.equal(Ok(model.Raw))
}

pub fn parse_runtime_based_rejected_test() {
  model.parse_runtime("based") |> should.be_error()
}

pub fn parse_runtime_native_test() {
  model.parse_runtime("native") |> should.equal(Ok(model.Native))
}

pub fn parse_runtime_invalid_test() {
  model.parse_runtime("fast") |> should.be_error()
}

// parse_query_command tests

pub fn parse_query_command_one_test() {
  model.parse_query_command(":one") |> should.equal(Ok(model.One))
}

pub fn parse_query_command_many_test() {
  model.parse_query_command(":many") |> should.equal(Ok(model.Many))
}

pub fn parse_query_command_exec_test() {
  model.parse_query_command(":exec") |> should.equal(Ok(model.Exec))
}

pub fn parse_query_command_execresult_test() {
  model.parse_query_command(":execresult")
  |> should.equal(Ok(model.ExecResult))
}

pub fn parse_query_command_execrows_test() {
  model.parse_query_command(":execrows") |> should.equal(Ok(model.ExecRows))
}

pub fn parse_query_command_execlastid_test() {
  model.parse_query_command(":execlastid")
  |> should.equal(Ok(model.ExecLastId))
}

pub fn parse_query_command_batchone_test() {
  model.parse_query_command(":batchone") |> should.equal(Ok(model.BatchOne))
}

pub fn parse_query_command_batchmany_test() {
  model.parse_query_command(":batchmany") |> should.equal(Ok(model.BatchMany))
}

pub fn parse_query_command_batchexec_test() {
  model.parse_query_command(":batchexec") |> should.equal(Ok(model.BatchExec))
}

pub fn parse_query_command_copyfrom_test() {
  model.parse_query_command(":copyfrom") |> should.equal(Ok(model.CopyFrom))
}

pub fn parse_query_command_invalid_test() {
  model.parse_query_command(":select") |> should.be_error()
}

// engine_to_string tests

pub fn engine_to_string_roundtrip_test() {
  model.engine_to_string(model.PostgreSQL) |> should.equal("postgresql")
  model.engine_to_string(model.MySQL) |> should.equal("mysql")
  model.engine_to_string(model.SQLite) |> should.equal("sqlite")
}

// runtime_to_string tests

pub fn runtime_to_string_roundtrip_test() {
  model.runtime_to_string(model.Raw) |> should.equal("raw")
  model.runtime_to_string(model.Native) |> should.equal("native")
}

// query_command_to_variant tests

pub fn query_command_to_variant_test() {
  model.query_command_to_variant(model.One) |> should.equal("QueryOne")
  model.query_command_to_variant(model.Many) |> should.equal("QueryMany")
  model.query_command_to_variant(model.Exec) |> should.equal("QueryExec")
  model.query_command_to_variant(model.ExecResult)
  |> should.equal("QueryExecResult")
  model.query_command_to_variant(model.ExecRows)
  |> should.equal("QueryExecRows")
  model.query_command_to_variant(model.ExecLastId)
  |> should.equal("QueryExecLastId")
}

// scalar_type_to_gleam_type tests

pub fn scalar_type_to_gleam_type_string_mapping_test() {
  let m = model.StringMapping
  model.scalar_type_to_gleam_type(model.IntType, m) |> should.equal("Int")
  model.scalar_type_to_gleam_type(model.FloatType, m) |> should.equal("Float")
  model.scalar_type_to_gleam_type(model.BoolType, m) |> should.equal("Bool")
  model.scalar_type_to_gleam_type(model.StringType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.BytesType, m)
  |> should.equal("BitArray")
  model.scalar_type_to_gleam_type(model.DateTimeType, m)
  |> should.equal("String")
  model.scalar_type_to_gleam_type(model.DateType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.TimeType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.UuidType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.JsonType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.EnumType("status"), m)
  |> should.equal("String")
  model.scalar_type_to_gleam_type(model.CustomType("UserId", model.IntType), m)
  |> should.equal("UserId")
}

pub fn scalar_type_to_gleam_type_rich_mapping_test() {
  let m = model.RichMapping
  model.scalar_type_to_gleam_type(model.IntType, m) |> should.equal("Int")
  model.scalar_type_to_gleam_type(model.FloatType, m) |> should.equal("Float")
  model.scalar_type_to_gleam_type(model.StringType, m) |> should.equal("String")
  model.scalar_type_to_gleam_type(model.DateTimeType, m)
  |> should.equal("SqlTimestamp")
  model.scalar_type_to_gleam_type(model.DateType, m)
  |> should.equal("SqlDate")
  model.scalar_type_to_gleam_type(model.TimeType, m)
  |> should.equal("SqlTime")
  model.scalar_type_to_gleam_type(model.UuidType, m)
  |> should.equal("SqlUuid")
  model.scalar_type_to_gleam_type(model.JsonType, m)
  |> should.equal("SqlJson")
  model.scalar_type_to_gleam_type(model.EnumType("status"), m)
  |> should.equal("String")
}

pub fn custom_type_delegates_to_underlying_test() {
  let custom = model.CustomType("UserId", model.IntType)
  model.scalar_type_to_runtime_function(custom)
  |> should.equal("runtime.int")
  model.scalar_type_to_db_name(custom) |> should.equal("int")
  model.scalar_type_to_value_function(model.PostgreSQL, custom)
  |> should.equal("int")
  model.scalar_type_to_decoder(model.PostgreSQL, custom)
  |> should.equal("decode.int")
}

// scalar_type_to_runtime_function tests

pub fn scalar_type_to_runtime_function_test() {
  model.scalar_type_to_runtime_function(model.IntType)
  |> should.equal("runtime.int")
  model.scalar_type_to_runtime_function(model.FloatType)
  |> should.equal("runtime.float")
  model.scalar_type_to_runtime_function(model.BoolType)
  |> should.equal("runtime.bool")
  model.scalar_type_to_runtime_function(model.StringType)
  |> should.equal("runtime.string")
  model.scalar_type_to_runtime_function(model.BytesType)
  |> should.equal("runtime.bytes")
  model.scalar_type_to_runtime_function(model.EnumType("status"))
  |> should.equal("runtime.string")
}
