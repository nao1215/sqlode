import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

pub fn infer_param_type_from_where_clause_test() {
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      content,
    )

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [get_author, list_authors] = analyzed

  get_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "id",
      scalar_type: model.IntType,
      nullable: False,
    ),
  ])
  list_authors.params |> should.equal([])
}

pub fn infer_insert_param_types_from_column_order_test() {
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      content,
    )

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [create_author] = analyzed

  create_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
    model.QueryParam(
      index: 2,
      field_name: "bio",
      scalar_type: model.StringType,
      nullable: True,
    ),
  ])
}

pub fn infer_result_columns_for_select_test() {
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      content,
    )

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [get_author, list_authors] = analyzed

  get_author.result_columns
  |> should.equal([
    model.ResultColumn(name: "id", scalar_type: model.IntType, nullable: False),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
  ])

  list_authors.result_columns
  |> should.equal([
    model.ResultColumn(name: "id", scalar_type: model.IntType, nullable: False),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
  ])
}

pub fn infer_no_result_columns_for_exec_test() {
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      content,
    )

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [create_author] = analyzed

  create_author.result_columns |> should.equal([])
}

pub fn infer_result_columns_with_star_test() {
  let catalog = test_catalog()
  let sql = "-- name: GetAllAuthors :many\nSELECT * FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("star.sql", model.PostgreSQL, sql)

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [get_all] = analyzed

  get_all.result_columns
  |> should.equal([
    model.ResultColumn(name: "id", scalar_type: model.IntType, nullable: False),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
    model.ResultColumn(
      name: "bio",
      scalar_type: model.StringType,
      nullable: True,
    ),
  ])
}

pub fn infer_result_columns_with_table_prefix_test() {
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorPrefixed :one\nSELECT authors.id, authors.name FROM authors WHERE authors.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("prefix.sql", model.PostgreSQL, sql)

  let analyzed =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, queries)
  let assert [get_author] = analyzed

  get_author.result_columns
  |> should.equal([
    model.ResultColumn(name: "id", scalar_type: model.IntType, nullable: False),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
  ])
}

fn test_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", content)])

  catalog
}
