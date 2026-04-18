import gleam/list
import gleam/option
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
  block.schema |> should.equal(["schema.sql"])
  block.queries |> should.equal(["query.sql"])
  block.gleam.out |> should.equal("../../test_output/db")
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
  string.contains(msg, "Valid keys: version, sql") |> should.be_true()
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

// type_mapping config

pub fn load_rich_type_mapping_config_test() {
  let assert Ok(cfg) = config.load("test/fixtures/rich_types.yaml")
  let assert [block] = cfg.sql
  block.gleam.type_mapping |> should.equal(model.RichMapping)
}

pub fn default_type_mapping_is_string_test() {
  let assert Ok(cfg) = config.load("test/fixtures/sqlode.yaml")
  let assert [block] = cfg.sql
  block.gleam.type_mapping |> should.equal(model.StringMapping)
}

// gleam_type validation

pub fn reject_lowercase_gleam_type_test() {
  let assert Error(error) =
    config.load("test/fixtures/invalid_gleam_type_lowercase.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "uppercase") |> should.be_true()
  string.contains(msg, "userId") |> should.be_true()
}

pub fn reject_empty_gleam_type_test() {
  let assert Error(error) =
    config.load("test/fixtures/invalid_gleam_type_empty.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "empty") |> should.be_true()
}

// malformed rename entries

pub fn reject_malformed_rename_entry_test() {
  let assert Error(error) = config.load("test/fixtures/malformed_rename.yaml")
  let msg = config.error_to_string(error)
  string.contains(msg, "renames") |> should.be_true()
  string.contains(msg, "rename_to") |> should.be_true()
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

// Named SQL blocks

pub fn load_named_sql_blocks_test() {
  let assert Ok(cfg) = config.load("test/fixtures/named_blocks.yaml")
  list.length(cfg.sql) |> should.equal(2)

  let assert [api_block, worker_block] = cfg.sql
  api_block.name |> should.equal(option.Some("api"))
  api_block.engine |> should.equal(model.PostgreSQL)
  worker_block.name |> should.equal(option.Some("worker"))
  worker_block.engine |> should.equal(model.SQLite)
}

pub fn default_block_name_is_none_test() {
  let assert Ok(cfg) = config.load("test/fixtures/sqlode.yaml")
  let assert [block] = cfg.sql
  block.name |> should.equal(option.None)
}

pub fn default_strict_views_is_true_test() {
  // A config that does not mention `strict_views` defaults to the
  // strict policy. Issue #391 tightened the default so partial view
  // resolution cannot silently reach codegen.
  let assert Ok(cfg) = config.load("test/fixtures/sqlode.yaml")
  let assert [block] = cfg.sql
  block.gleam.strict_views |> should.equal(True)
}

pub fn strict_views_true_roundtrips_test() {
  let assert Ok(cfg) = config.load("test/fixtures/strict_views_enabled.yaml")
  let assert [block] = cfg.sql
  block.gleam.strict_views |> should.equal(True)
}
