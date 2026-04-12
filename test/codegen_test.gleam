import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/codegen
import sqlode/model
import sqlode/query_parser

pub fn main() {
  gleeunit.main()
}

pub fn render_queries_module_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      content,
    )

  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        package: "db",
        out: "test_output/db",
        runtime: model.Raw,
      ),
    )

  let rendered = codegen.render_queries_module(block, queries)

  string.contains(rendered, "pub fn get_author() -> Query {")
  |> should.be_true()
  string.contains(rendered, "command: QueryOne")
  |> should.be_true()
  string.contains(rendered, "pub fn all() -> List(Query) {")
  |> should.be_true()
  list.length(queries) |> should.equal(2)
}
