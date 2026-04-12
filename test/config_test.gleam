import gleam/list
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
