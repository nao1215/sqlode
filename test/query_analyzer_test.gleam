import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

pub fn infer_param_type_from_where_clause_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [get_author, list_authors] = analyzed

  get_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "id",
      scalar_type: model.IntType,
      nullable: False,
      is_list: False,
    ),
  ])
  list_authors.params |> should.equal([])
}

pub fn infer_insert_param_types_from_column_order_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [create_author] = analyzed

  create_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
    model.QueryParam(
      index: 2,
      field_name: "bio",
      scalar_type: model.StringType,
      nullable: True,
      is_list: False,
    ),
  ])
}

pub fn infer_result_columns_for_select_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
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
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [create_author] = analyzed

  create_author.result_columns |> should.equal([])
}

pub fn infer_result_columns_with_star_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql = "-- name: GetAllAuthors :many\nSELECT * FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("star.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
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
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorPrefixed :one\nSELECT authors.id, authors.name FROM authors WHERE authors.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("prefix.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
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

pub fn sqlc_arg_sets_param_name_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByName :one\nSELECT id, name FROM authors WHERE name = sqlc.arg(author_name);"
  let assert Ok(queries) =
    query_parser.parse_file("arg.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "author_name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
  ])
}

pub fn sqlc_narg_sets_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: UpdateBio :exec\nUPDATE authors SET bio = sqlc.narg(new_bio) WHERE id = sqlc.arg(author_id);"
  let assert Ok(queries) =
    query_parser.parse_file("narg.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [bio_param, id_param] = query.params
  bio_param.field_name |> should.equal("new_bio")
  bio_param.nullable |> should.equal(True)
  id_param.field_name |> should.equal("author_id")
  id_param.nullable |> should.equal(False)
}

pub fn sqlc_slice_sets_is_list_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByIds :many\nSELECT id, name FROM authors WHERE id IN (sqlc.slice(ids));"
  let assert Ok(queries) =
    query_parser.parse_file("slice.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [param] = query.params
  param.field_name |> should.equal("ids")
  param.is_list |> should.equal(True)
}

pub fn parse_enum_column_type_test() {
  let schema =
    "CREATE TYPE status AS ENUM ('active', 'inactive', 'banned');\n"
    <> "CREATE TABLE users (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL,\n"
    <> "  status status NOT NULL\n"
    <> ");"

  let assert Ok(catalog) = schema_parser.parse_files([#("enum.sql", schema)])

  let assert [table] = catalog.tables
  let assert [_id, _name, status_col] = table.columns
  status_col.scalar_type |> should.equal(model.EnumType("status"))

  let assert [enum_def] = catalog.enums
  enum_def.name |> should.equal("status")
  enum_def.values |> should.equal(["active", "inactive", "banned"])
}

pub fn join_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("join.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
  ])
}

pub fn sqlc_embed_expands_table_columns_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookFull :one\nSELECT sqlc.embed(authors), books.title FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("embed.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [id_col, name_col, bio_col, title_col] = query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
  bio_col.name |> should.equal("bio")
  bio_col.nullable |> should.equal(True)
  title_col.name |> should.equal("title")
}

pub fn returning_clause_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: CreateAuthorReturning :one\nINSERT INTO authors (name, bio) VALUES ($1, $2) RETURNING id, name;"
  let assert Ok(queries) =
    query_parser.parse_file("ret.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ResultColumn(name: "id", scalar_type: model.IntType, nullable: False),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
    ),
  ])
}

pub fn cte_select_from_real_table_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetRecentAuthors :many\nWITH filtered AS (SELECT id FROM authors WHERE id > 0) SELECT authors.id, authors.name FROM authors JOIN filtered ON authors.id = filtered.id;"
  let assert Ok(queries) =
    query_parser.parse_file("cte.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [id_col, name_col] = query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
}

fn test_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", content)])

  catalog
}

fn join_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/join_schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([#("test/fixtures/join_schema.sql", content)])

  catalog
}
