import gleam/list
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

pub fn parse_create_table_columns_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", content)])

  list.length(catalog.tables) |> should.equal(1)
  let assert [table] = catalog.tables
  table.name |> should.equal("authors")
  list.length(table.columns) |> should.equal(3)

  let assert [id, name, bio] = table.columns
  id.name |> should.equal("id")
  id.scalar_type |> should.equal(model.IntType)
  id.nullable |> should.equal(False)
  name.scalar_type |> should.equal(model.StringType)
  name.nullable |> should.equal(False)
  bio.nullable |> should.equal(True)
}
