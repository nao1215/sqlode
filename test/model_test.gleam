import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import sqlode/model
import sqlode/runtime
import sqlode/type_mapping

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
  model.parse_query_command(":one") |> should.equal(Ok(runtime.QueryOne))
}

pub fn parse_query_command_many_test() {
  model.parse_query_command(":many") |> should.equal(Ok(runtime.QueryMany))
}

pub fn parse_query_command_exec_test() {
  model.parse_query_command(":exec") |> should.equal(Ok(runtime.QueryExec))
}

pub fn parse_query_command_execresult_test() {
  model.parse_query_command(":execresult")
  |> should.equal(Ok(runtime.QueryExecResult))
}

pub fn parse_query_command_execrows_test() {
  model.parse_query_command(":execrows")
  |> should.equal(Ok(runtime.QueryExecRows))
}

pub fn parse_query_command_execlastid_test() {
  model.parse_query_command(":execlastid")
  |> should.equal(Ok(runtime.QueryExecLastId))
}

pub fn parse_query_command_batchone_test() {
  model.parse_query_command(":batchone")
  |> should.equal(Ok(runtime.QueryBatchOne))
}

pub fn parse_query_command_batchmany_test() {
  model.parse_query_command(":batchmany")
  |> should.equal(Ok(runtime.QueryBatchMany))
}

pub fn parse_query_command_batchexec_test() {
  model.parse_query_command(":batchexec")
  |> should.equal(Ok(runtime.QueryBatchExec))
}

pub fn parse_query_command_copyfrom_test() {
  model.parse_query_command(":copyfrom")
  |> should.equal(Ok(runtime.QueryCopyFrom))
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

// query_command_to_string tests

pub fn query_command_to_string_test() {
  model.query_command_to_string(runtime.QueryOne)
  |> should.equal("QueryOne")
  model.query_command_to_string(runtime.QueryMany)
  |> should.equal("QueryMany")
  model.query_command_to_string(runtime.QueryExec)
  |> should.equal("QueryExec")
  model.query_command_to_string(runtime.QueryExecResult)
  |> should.equal("QueryExecResult")
  model.query_command_to_string(runtime.QueryExecRows)
  |> should.equal("QueryExecRows")
  model.query_command_to_string(runtime.QueryExecLastId)
  |> should.equal("QueryExecLastId")
}

// scalar_type_to_gleam_type tests

pub fn scalar_type_to_gleam_type_string_mapping_test() {
  let m = model.StringMapping
  type_mapping.scalar_type_to_gleam_type(model.IntType, m)
  |> should.equal("Int")
  type_mapping.scalar_type_to_gleam_type(model.FloatType, m)
  |> should.equal("Float")
  type_mapping.scalar_type_to_gleam_type(model.BoolType, m)
  |> should.equal("Bool")
  type_mapping.scalar_type_to_gleam_type(model.StringType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.BytesType, m)
  |> should.equal("BitArray")
  type_mapping.scalar_type_to_gleam_type(model.DateTimeType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.DateType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.TimeType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.UuidType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.JsonType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.EnumType("status"), m)
  |> should.equal("Status")
  type_mapping.scalar_type_to_gleam_type(
    model.CustomType("UserId", option.None, model.IntType),
    m,
  )
  |> should.equal("UserId")
}

pub fn scalar_type_to_gleam_type_rich_mapping_test() {
  let m = model.RichMapping
  type_mapping.scalar_type_to_gleam_type(model.IntType, m)
  |> should.equal("Int")
  type_mapping.scalar_type_to_gleam_type(model.FloatType, m)
  |> should.equal("Float")
  type_mapping.scalar_type_to_gleam_type(model.StringType, m)
  |> should.equal("String")
  type_mapping.scalar_type_to_gleam_type(model.DateTimeType, m)
  |> should.equal("SqlTimestamp")
  type_mapping.scalar_type_to_gleam_type(model.DateType, m)
  |> should.equal("SqlDate")
  type_mapping.scalar_type_to_gleam_type(model.TimeType, m)
  |> should.equal("SqlTime")
  type_mapping.scalar_type_to_gleam_type(model.UuidType, m)
  |> should.equal("SqlUuid")
  type_mapping.scalar_type_to_gleam_type(model.JsonType, m)
  |> should.equal("SqlJson")
  type_mapping.scalar_type_to_gleam_type(model.EnumType("status"), m)
  |> should.equal("Status")
}

pub fn custom_type_delegates_to_underlying_test() {
  let custom = model.CustomType("UserId", option.None, model.IntType)
  type_mapping.scalar_type_to_runtime_function(custom)
  |> should.equal("runtime.int")
  type_mapping.scalar_type_to_db_name(custom) |> should.equal("int")
  type_mapping.scalar_type_to_value_function(model.PostgreSQL, custom)
  |> should.equal("int")
  type_mapping.scalar_type_to_decoder(model.PostgreSQL, custom)
  |> should.equal("decode.int")
}

// scalar_type_to_runtime_function tests

pub fn scalar_type_to_runtime_function_test() {
  type_mapping.scalar_type_to_runtime_function(model.IntType)
  |> should.equal("runtime.int")
  type_mapping.scalar_type_to_runtime_function(model.FloatType)
  |> should.equal("runtime.float")
  type_mapping.scalar_type_to_runtime_function(model.BoolType)
  |> should.equal("runtime.bool")
  type_mapping.scalar_type_to_runtime_function(model.StringType)
  |> should.equal("runtime.string")
  type_mapping.scalar_type_to_runtime_function(model.BytesType)
  |> should.equal("runtime.bytes")
  type_mapping.scalar_type_to_runtime_function(model.EnumType("status"))
  |> should.equal("runtime.string")
}

// parse_type_mapping tests

pub fn parse_type_mapping_string_test() {
  model.parse_type_mapping("string") |> should.equal(Ok(model.StringMapping))
}

pub fn parse_type_mapping_rich_test() {
  model.parse_type_mapping("rich") |> should.equal(Ok(model.RichMapping))
}

pub fn parse_type_mapping_strong_test() {
  model.parse_type_mapping("strong") |> should.equal(Ok(model.StrongMapping))
}

pub fn parse_type_mapping_invalid_test() {
  let assert Error(msg) = model.parse_type_mapping("unknown")
  string.contains(msg, "string") |> should.be_true()
  string.contains(msg, "rich") |> should.be_true()
  string.contains(msg, "strong") |> should.be_true()
}

pub fn strong_type_uses_same_names_as_rich_test() {
  type_mapping.scalar_type_to_gleam_type(model.UuidType, model.StrongMapping)
  |> should.equal("SqlUuid")
  type_mapping.scalar_type_to_gleam_type(
    model.DateTimeType,
    model.StrongMapping,
  )
  |> should.equal("SqlTimestamp")
}

pub fn strong_type_unwrap_fn_test() {
  type_mapping.strong_type_unwrap_fn(model.UuidType)
  |> should.equal(option.Some("sql_uuid_to_string"))
  type_mapping.strong_type_unwrap_fn(model.JsonType)
  |> should.equal(option.Some("sql_json_to_string"))
  type_mapping.strong_type_unwrap_fn(model.IntType)
  |> should.equal(option.None)
  type_mapping.strong_type_unwrap_fn(model.StringType)
  |> should.equal(option.None)
}

// is_rich_type tests

pub fn is_rich_type_datetime_test() {
  type_mapping.is_rich_type(model.DateTimeType) |> should.be_true()
  type_mapping.is_rich_type(model.DateType) |> should.be_true()
  type_mapping.is_rich_type(model.TimeType) |> should.be_true()
  type_mapping.is_rich_type(model.UuidType) |> should.be_true()
  type_mapping.is_rich_type(model.JsonType) |> should.be_true()
}

pub fn is_rich_type_non_rich_test() {
  type_mapping.is_rich_type(model.IntType) |> should.be_false()
  type_mapping.is_rich_type(model.FloatType) |> should.be_false()
  type_mapping.is_rich_type(model.BoolType) |> should.be_false()
  type_mapping.is_rich_type(model.StringType) |> should.be_false()
  type_mapping.is_rich_type(model.BytesType) |> should.be_false()
  type_mapping.is_rich_type(model.EnumType("status")) |> should.be_false()
}

// scalar_type_to_decoder tests

pub fn scalar_type_to_decoder_sqlite_bool_test() {
  type_mapping.scalar_type_to_decoder(model.SQLite, model.BoolType)
  |> string.contains("decode.then")
  |> should.be_true()
}

pub fn scalar_type_to_decoder_postgresql_bool_test() {
  type_mapping.scalar_type_to_decoder(model.PostgreSQL, model.BoolType)
  |> should.equal("decode.bool")
}

// scalar_type_to_value_function tests

pub fn scalar_type_to_value_function_bytes_postgresql_test() {
  type_mapping.scalar_type_to_value_function(model.PostgreSQL, model.BytesType)
  |> should.equal("bytea")
}

pub fn scalar_type_to_value_function_bytes_sqlite_test() {
  type_mapping.scalar_type_to_value_function(model.SQLite, model.BytesType)
  |> should.equal("blob")
}

// enum helper function tests

pub fn enum_type_name_test() {
  type_mapping.enum_type_name("status") |> should.equal("Status")
  type_mapping.enum_type_name("user_role") |> should.equal("UserRole")
}

pub fn enum_value_name_test() {
  type_mapping.enum_value_name("active") |> should.equal("Active")
  type_mapping.enum_value_name("in_progress") |> should.equal("InProgress")
}

pub fn enum_to_string_fn_test() {
  type_mapping.enum_to_string_fn("status") |> should.equal("status_to_string")
  type_mapping.enum_to_string_fn("UserRole")
  |> should.equal("userrole_to_string")
}

pub fn enum_from_string_fn_test() {
  type_mapping.enum_from_string_fn("status")
  |> should.equal("status_from_string")
}

// array type tests

pub fn parse_sql_type_array_text_test() {
  model.parse_sql_type("TEXT[]")
  |> should.equal(Ok(model.ArrayType(model.StringType)))
}

pub fn parse_sql_type_array_integer_test() {
  model.parse_sql_type("INTEGER[]")
  |> should.equal(Ok(model.ArrayType(model.IntType)))
}

pub fn parse_sql_type_array_boolean_test() {
  model.parse_sql_type("BOOLEAN[]")
  |> should.equal(Ok(model.ArrayType(model.BoolType)))
}

pub fn parse_sql_type_array_uuid_test() {
  model.parse_sql_type("UUID[]")
  |> should.equal(Ok(model.ArrayType(model.UuidType)))
}

pub fn scalar_type_to_gleam_type_array_test() {
  type_mapping.scalar_type_to_gleam_type(
    model.ArrayType(model.IntType),
    model.StringMapping,
  )
  |> should.equal("List(Int)")

  type_mapping.scalar_type_to_gleam_type(
    model.ArrayType(model.StringType),
    model.StringMapping,
  )
  |> should.equal("List(String)")
}

pub fn scalar_type_to_decoder_array_test() {
  type_mapping.scalar_type_to_decoder(
    model.PostgreSQL,
    model.ArrayType(model.IntType),
  )
  |> should.equal("decode.list(decode.int)")

  type_mapping.scalar_type_to_decoder(
    model.PostgreSQL,
    model.ArrayType(model.StringType),
  )
  |> should.equal("decode.list(decode.string)")
}

pub fn scalar_type_to_value_function_array_test() {
  type_mapping.scalar_type_to_value_function(
    model.PostgreSQL,
    model.ArrayType(model.IntType),
  )
  |> should.equal("array(pog.int)")

  type_mapping.scalar_type_to_value_function(
    model.PostgreSQL,
    model.ArrayType(model.StringType),
  )
  |> should.equal("array(pog.text)")
}

pub fn scalar_type_to_db_name_array_test() {
  type_mapping.scalar_type_to_db_name(model.ArrayType(model.IntType))
  |> should.equal("int[]")
}

// PostgreSQL-specific type tests

pub fn parse_sql_type_interval_test() {
  model.parse_sql_type("INTERVAL")
  |> should.equal(Ok(model.TimeType))
}

pub fn parse_sql_type_money_test() {
  model.parse_sql_type("MONEY")
  |> should.equal(Ok(model.FloatType))
}

pub fn parse_sql_type_citext_test() {
  model.parse_sql_type("CITEXT")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_inet_test() {
  model.parse_sql_type("INET")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_cidr_test() {
  model.parse_sql_type("CIDR")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_macaddr_test() {
  model.parse_sql_type("MACADDR")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_tsvector_test() {
  model.parse_sql_type("TSVECTOR")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_point_test() {
  model.parse_sql_type("POINT")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_xml_test() {
  model.parse_sql_type("XML")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_bit_test() {
  model.parse_sql_type("BIT")
  |> should.equal(Ok(model.StringType))
  model.parse_sql_type("BIT VARYING")
  |> should.equal(Ok(model.StringType))
}

// Normalized-type-parser regression tests (Issue #361)

pub fn parse_sql_type_bigint_test() {
  model.parse_sql_type("BIGINT")
  |> should.equal(Ok(model.IntType))
  model.parse_sql_type("bigint")
  |> should.equal(Ok(model.IntType))
}

pub fn parse_sql_type_smallint_test() {
  model.parse_sql_type("SMALLINT")
  |> should.equal(Ok(model.IntType))
}

pub fn parse_sql_type_serial_family_test() {
  model.parse_sql_type("SERIAL")
  |> should.equal(Ok(model.IntType))
  model.parse_sql_type("BIGSERIAL")
  |> should.equal(Ok(model.IntType))
  model.parse_sql_type("SMALLSERIAL")
  |> should.equal(Ok(model.IntType))
}

pub fn parse_sql_type_numeric_with_precision_test() {
  model.parse_sql_type("NUMERIC(10,2)")
  |> should.equal(Ok(model.FloatType))
  model.parse_sql_type("numeric ( 10 , 2 )")
  |> should.equal(Ok(model.FloatType))
}

pub fn parse_sql_type_decimal_with_precision_test() {
  model.parse_sql_type("DECIMAL(5)")
  |> should.equal(Ok(model.FloatType))
}

pub fn parse_sql_type_double_precision_test() {
  model.parse_sql_type("DOUBLE PRECISION")
  |> should.equal(Ok(model.FloatType))
}

pub fn parse_sql_type_varchar_with_length_test() {
  model.parse_sql_type("VARCHAR(32)")
  |> should.equal(Ok(model.StringType))
  model.parse_sql_type("varchar ( 32 )")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_character_varying_test() {
  model.parse_sql_type("CHARACTER VARYING")
  |> should.equal(Ok(model.StringType))
  model.parse_sql_type("character varying(100)")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_timestamp_test() {
  model.parse_sql_type("TIMESTAMP")
  |> should.equal(Ok(model.DateTimeType))
}

pub fn parse_sql_type_timestamptz_test() {
  model.parse_sql_type("TIMESTAMPTZ")
  |> should.equal(Ok(model.DateTimeType))
  model.parse_sql_type("TIMESTAMP WITH TIME ZONE")
  |> should.equal(Ok(model.DateTimeType))
  model.parse_sql_type("timestamp without time zone")
  |> should.equal(Ok(model.DateTimeType))
}

pub fn parse_sql_type_time_with_time_zone_test() {
  model.parse_sql_type("TIME WITH TIME ZONE")
  |> should.equal(Ok(model.TimeType))
  model.parse_sql_type("TIMETZ")
  |> should.equal(Ok(model.TimeType))
}

pub fn parse_sql_type_boolean_test() {
  model.parse_sql_type("BOOLEAN")
  |> should.equal(Ok(model.BoolType))
  model.parse_sql_type("BOOL")
  |> should.equal(Ok(model.BoolType))
}

pub fn parse_sql_type_json_test() {
  model.parse_sql_type("JSON")
  |> should.equal(Ok(model.JsonType))
  model.parse_sql_type("JSONB")
  |> should.equal(Ok(model.JsonType))
}

pub fn parse_sql_type_whitespace_is_normalized_test() {
  model.parse_sql_type("  TIMESTAMP   WITH   TIME ZONE  ")
  |> should.equal(Ok(model.DateTimeType))
}

pub fn parse_sql_type_array_with_modifier_test() {
  model.parse_sql_type("NUMERIC(10,2)[]")
  |> should.equal(Ok(model.ArrayType(model.FloatType)))
  model.parse_sql_type("VARCHAR(50)[]")
  |> should.equal(Ok(model.ArrayType(model.StringType)))
}

pub fn parse_sql_type_array_keyword_suffix_test() {
  model.parse_sql_type("INTEGER ARRAY")
  |> should.equal(Ok(model.ArrayType(model.IntType)))
}

pub fn parse_sql_type_unknown_test() {
  model.parse_sql_type("unknowntype")
  |> should.equal(Error(Nil))
  model.parse_sql_type("GEOMETRY")
  |> should.equal(Error(Nil))
}

pub fn parse_sql_type_schema_qualified_is_unknown_test() {
  model.parse_sql_type("public.my_enum")
  |> should.equal(Error(Nil))
}

pub fn parse_sql_type_rejects_substring_false_positive_test() {
  // "bigfloat" contains "float" but is not a real SQL type; under the
  // substring matcher it resolved to FloatType. With normalized matching
  // it is now correctly rejected.
  model.parse_sql_type("bigfloat")
  |> should.equal(Error(Nil))
}

pub fn parse_sql_type_point_is_string_not_int_test() {
  // "point" contains "int" as a substring. The normalized parser must
  // classify it as StringType without depending on rule ordering.
  model.parse_sql_type("POINT")
  |> should.equal(Ok(model.StringType))
}

pub fn parse_sql_type_interval_is_time_not_int_test() {
  model.parse_sql_type("INTERVAL")
  |> should.equal(Ok(model.TimeType))
}
