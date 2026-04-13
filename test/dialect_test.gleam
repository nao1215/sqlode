import gleam/list
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

// ============================================================
// MySQL dialect tests
// ============================================================

pub fn mysql_positional_placeholder_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/mysql_query.sql", model.MySQL, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  // GetAuthor :one - single ? placeholder
  let assert Ok(get) = list.find(analyzed, fn(q) { q.base.name == "GetAuthor" })
  get.base.param_count |> should.equal(1)
  list.length(get.params) |> should.equal(1)
  let assert [param] = get.params
  param.index |> should.equal(1)
  param.scalar_type |> should.equal(model.IntType)
}

pub fn mysql_insert_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/mysql_query.sql", model.MySQL, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  let assert Ok(create) =
    list.find(analyzed, fn(q) { q.base.name == "CreateAuthor" })
  create.base.param_count |> should.equal(2)
  list.length(create.params) |> should.equal(2)

  let assert [name_param, bio_param] = create.params
  name_param.field_name |> should.equal("name")
  name_param.scalar_type |> should.equal(model.StringType)
  bio_param.field_name |> should.equal("bio")
  bio_param.nullable |> should.equal(True)
}

pub fn mysql_update_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/mysql_query.sql", model.MySQL, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  let assert Ok(update) =
    list.find(analyzed, fn(q) { q.base.name == "UpdateAuthor" })
  update.base.param_count |> should.equal(3)
  list.length(update.params) |> should.equal(3)
}

pub fn mysql_no_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/mysql_query.sql", model.MySQL, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  let assert Ok(list_q) =
    list.find(analyzed, fn(q) { q.base.name == "ListAuthors" })
  list_q.base.param_count |> should.equal(0)
  list_q.params |> should.equal([])
}

pub fn mysql_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/mysql_query.sql", model.MySQL, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  let assert Ok(get) = list.find(analyzed, fn(q) { q.base.name == "GetAuthor" })
  list.length(get.result_columns) |> should.equal(2)
  let assert [id_col, name_col] = get.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
}

// ============================================================
// SQLite dialect tests
// ============================================================

pub fn sqlite_numbered_placeholder_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(get_by_id) =
    list.find(analyzed, fn(q) { q.base.name == "GetAuthorById" })
  get_by_id.base.param_count |> should.equal(1)
  let assert [param] = get_by_id.params
  param.index |> should.equal(1)
}

pub fn sqlite_colon_named_placeholder_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(get_by_name) =
    list.find(analyzed, fn(q) { q.base.name == "GetAuthorByName" })
  get_by_name.base.param_count |> should.equal(1)
  let assert [param] = get_by_name.params
  param.field_name |> should.equal("name")
}

pub fn sqlite_at_named_placeholder_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(get_by_email) =
    list.find(analyzed, fn(q) { q.base.name == "GetAuthorByEmail" })
  get_by_email.base.param_count |> should.equal(1)
  let assert [param] = get_by_email.params
  // @author_name shorthand is equivalent to sqlc.arg(author_name)
  param.field_name |> should.equal("author_name")
  param.scalar_type |> should.equal(model.StringType)
}

pub fn sqlite_dollar_named_placeholder_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(get_by_slug) =
    list.find(analyzed, fn(q) { q.base.name == "GetAuthorBySlug" })
  get_by_slug.base.param_count |> should.equal(1)
  let assert [param] = get_by_slug.params
  // Column inference resolves to "name" (from equality match authors.name)
  param.field_name |> should.equal("name")
  param.scalar_type |> should.equal(model.StringType)
}

pub fn sqlite_insert_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(create) =
    list.find(analyzed, fn(q) { q.base.name == "CreateAuthor" })
  create.base.param_count |> should.equal(2)
  let assert [name_param, bio_param] = create.params
  name_param.field_name |> should.equal("name")
  name_param.scalar_type |> should.equal(model.StringType)
  bio_param.field_name |> should.equal("bio")
}

pub fn sqlite_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries("test/fixtures/sqlite_query.sql", model.SQLite, naming_ctx)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert Ok(list_q) =
    list.find(analyzed, fn(q) { q.base.name == "ListAuthors" })
  list.length(list_q.result_columns) |> should.equal(2)
}

// ============================================================
// Cross-engine: same schema, different placeholder styles
// ============================================================

pub fn cross_engine_select_produces_same_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")

  let pg_sql = "-- name: ListAuthors :many\nSELECT id, name FROM authors;"
  let my_sql = "-- name: ListAuthors :many\nSELECT id, name FROM authors;"
  let sl_sql = "-- name: ListAuthors :many\nSELECT id, name FROM authors;"

  let assert Ok(pg_q) =
    query_parser.parse_file("pg.sql", model.PostgreSQL, naming_ctx, pg_sql)
  let assert Ok(my_q) =
    query_parser.parse_file("my.sql", model.MySQL, naming_ctx, my_sql)
  let assert Ok(sl_q) =
    query_parser.parse_file("sl.sql", model.SQLite, naming_ctx, sl_sql)

  let assert Ok(pg_analyzed) =
    query_analyzer.analyze_queries(model.PostgreSQL, catalog, naming_ctx, pg_q)
  let assert Ok(my_analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, my_q)
  let assert Ok(sl_analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, sl_q)

  let assert [pg] = pg_analyzed
  let assert [my] = my_analyzed
  let assert [sl] = sl_analyzed

  // Result columns should be identical regardless of engine
  pg.result_columns |> should.equal(my.result_columns)
  my.result_columns |> should.equal(sl.result_columns)
}

// ============================================================
// ExecResult, ExecRows, ExecLastId command types
// ============================================================

pub fn exec_result_command_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let sql =
    "-- name: DeleteAuthor :execresult\nDELETE FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("er.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [query] = analyzed
  query.base.command |> should.equal(model.ExecResult)
  query.result_columns |> should.equal([])
  query.base.param_count |> should.equal(1)
}

pub fn exec_rows_command_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let sql =
    "-- name: DeleteAllInactive :execrows\nDELETE FROM authors WHERE bio IS NULL;"
  let assert Ok(queries) =
    query_parser.parse_file("rows.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [query] = analyzed
  query.base.command |> should.equal(model.ExecRows)
  query.result_columns |> should.equal([])
}

pub fn exec_last_id_command_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let sql =
    "-- name: InsertAuthor :execlastid\nINSERT INTO authors (name, bio) VALUES (?, ?);"
  let assert Ok(queries) =
    query_parser.parse_file("lid.sql", model.MySQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)

  let assert [query] = analyzed
  query.base.command |> should.equal(model.ExecLastId)
  query.result_columns |> should.equal([])
}

// ============================================================
// Helpers
// ============================================================

fn load_catalog(path: String) -> model.Catalog {
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(catalog) = schema_parser.parse_files([#(path, content)])
  catalog
}

fn parse_queries(
  path: String,
  engine: model.Engine,
  naming_ctx: naming.NamingContext,
) -> List(model.ParsedQuery) {
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(queries) =
    query_parser.parse_file(path, engine, naming_ctx, content)
  queries
}
