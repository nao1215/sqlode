import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import sqlode/config
import sqlode/model

pub fn main() {
  gleeunit.main()
}

pub fn load_sqlc_style_config_test() {
  let assert Ok(cfg) = config.load("test/fixtures/sqlode.yaml")
  list.length(cfg.sql) |> should.equal(1)

  let assert [block] = cfg.sql
  block.engine |> should.equal(model.PostgreSQL)
  block.schema |> should.equal(["test/fixtures/schema.sql"])
  block.queries |> should.equal(["test/fixtures/query.sql"])
  block.gleam.package |> should.equal("db")
  block.gleam.out |> should.equal("test_output/db")
  block.gleam.runtime |> should.equal(model.Raw)
}

pub fn reject_unsupported_config_version_test() {
  let assert Error(error) = config.load("test/fixtures/invalid_version.yaml")

  config.error_to_string(error)
  |> should.equal("Invalid value for version: expected \"2\", got 1")
}

// Error cases

pub fn file_not_found_test() {
  let assert Error(error) = config.load("nonexistent/path/sqlode.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "not found") |> should.be_true()
}

pub fn sql_not_a_list_test() {
  let assert Error(error) = config.load("test/fixtures/malformed.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "sql") |> should.be_true()
}

pub fn missing_sql_field_test() {
  let assert Error(error) = config.load("test/fixtures/missing_sql.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "sql") |> should.be_true()
}

pub fn missing_engine_field_test() {
  let assert Error(error) = config.load("test/fixtures/missing_engine.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "engine") |> should.be_true()
}

pub fn invalid_engine_value_test() {
  let assert Error(error) = config.load("test/fixtures/invalid_engine.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "engine") |> should.be_true()
}

// Unsupported field rejection

pub fn reject_unsupported_root_field_test() {
  let assert Error(error) =
    config.load("test/fixtures/unsupported_root_field.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "database") |> should.be_true()
  string.contains(msg, "Unsupported") |> should.be_true()
}

pub fn reject_unsupported_sql_block_field_test() {
  let assert Error(error) =
    config.load("test/fixtures/unsupported_sql_field.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "emit_exact_table_names") |> should.be_true()
  string.contains(msg, "Unsupported") |> should.be_true()
}

pub fn reject_unsupported_gen_gleam_field_test() {
  let assert Error(error) =
    config.load("test/fixtures/unsupported_gen_field.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "emit_json_tags") |> should.be_true()
  string.contains(msg, "Unsupported") |> should.be_true()
}

pub fn reject_multiple_unsupported_root_fields_test() {
  let assert Error(error) =
    config.load("test/fixtures/unsupported_multiple_fields.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "database") |> should.be_true()
  string.contains(msg, "analyzer") |> should.be_true()
}

// MySQL + native runtime rejection

pub fn reject_mysql_native_runtime_test() {
  let assert Error(error) = config.load("test/fixtures/mysql_native.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "MySQL") |> should.be_true()
  string.contains(msg, "raw") |> should.be_true()
}

// error_to_string coverage

pub fn error_to_string_file_read_error_test() {
  config.error_to_string(config.FileReadError(
    path: "foo.yaml",
    detail: "permission denied",
  ))
  |> string.contains("foo.yaml")
  |> should.be_true()
}

pub fn error_to_string_unsupported_fields_test() {
  config.error_to_string(config.UnsupportedFields(
    fields: ["database", "analyzer"],
    message: "not supported by sqlode",
  ))
  |> string.contains("database")
  |> should.be_true()
}

pub fn error_to_string_missing_field_test() {
  config.error_to_string(config.MissingField(field: "engine"))
  |> string.contains("engine")
  |> should.be_true()
}
