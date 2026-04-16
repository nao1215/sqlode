import gleam/list
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/runtime
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

// ============================================================
// All SQL types: schema parsing and type inference
// ============================================================

pub fn all_types_schema_parsing_test() {
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let assert [table] = catalog.tables
  table.name |> should.equal("all_types")

  let assert [
    id,
    col_int,
    col_smallint,
    col_bigint,
    col_serial,
    col_float,
    col_double,
    col_real,
    col_numeric,
    col_decimal,
    col_bool,
    col_text,
    col_varchar,
    col_char,
    col_bytea,
    col_timestamp,
    col_datetime,
    col_date,
    col_time,
    col_timetz,
    col_uuid,
    col_json,
    col_jsonb,
  ] = table.columns

  // Integer types
  id.scalar_type |> should.equal(model.IntType)
  col_int.scalar_type |> should.equal(model.IntType)
  col_smallint.scalar_type |> should.equal(model.IntType)
  col_bigint.scalar_type |> should.equal(model.IntType)
  col_serial.scalar_type |> should.equal(model.IntType)

  // Float types
  col_float.scalar_type |> should.equal(model.FloatType)
  col_double.scalar_type |> should.equal(model.FloatType)
  col_real.scalar_type |> should.equal(model.FloatType)
  col_numeric.scalar_type |> should.equal(model.FloatType)
  col_decimal.scalar_type |> should.equal(model.FloatType)

  // Bool
  col_bool.scalar_type |> should.equal(model.BoolType)

  // String types
  col_text.scalar_type |> should.equal(model.StringType)
  col_varchar.scalar_type |> should.equal(model.StringType)
  col_char.scalar_type |> should.equal(model.StringType)

  // Bytes
  col_bytea.scalar_type |> should.equal(model.BytesType)

  // Date/time types
  col_timestamp.scalar_type |> should.equal(model.DateTimeType)
  col_datetime.scalar_type |> should.equal(model.DateTimeType)
  col_date.scalar_type |> should.equal(model.DateType)
  col_time.scalar_type |> should.equal(model.TimeType)
  col_timetz.scalar_type |> should.equal(model.TimeType)

  // UUID
  col_uuid.scalar_type |> should.equal(model.UuidType)

  // JSON types
  col_json.scalar_type |> should.equal(model.JsonType)
  col_jsonb.scalar_type |> should.equal(model.JsonType)
}

pub fn all_types_nullable_detection_test() {
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let assert [table] = catalog.tables

  let nullable_cols =
    table.columns
    |> list.filter(fn(col) { col.nullable })
    |> list.map(fn(col) { col.name })

  nullable_cols
  |> should.equal(["col_datetime", "col_timetz", "col_json", "col_jsonb"])
}

pub fn all_types_result_columns_star_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/all_types_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [get_all, list_all, _insert] = analyzed

  // :one with SELECT * should return all columns
  list.length(get_all.result_columns) |> should.equal(23)
  let assert [id_col, ..] = get_all.result_columns
  id_col.name |> should.equal("id")
  let assert model.ResultColumn(scalar_type: id_col_type, ..) = id_col
  id_col_type |> should.equal(model.IntType)

  // :many with SELECT * should also return all columns
  list.length(list_all.result_columns) |> should.equal(23)
}

pub fn all_types_insert_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/all_types_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [_get, _list, insert] = analyzed
  // INSERT has 21 placeholders ($1..$21)
  insert.base.param_count |> should.equal(21)
}

// ============================================================
// Complex schema: multiple tables, foreign keys, constraints
// ============================================================

pub fn complex_schema_multiple_tables_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  list.length(catalog.tables) |> should.equal(6)

  let table_names = list.map(catalog.tables, fn(t) { t.name })
  list.contains(table_names, "categories") |> should.be_true()
  list.contains(table_names, "users") |> should.be_true()
  list.contains(table_names, "posts") |> should.be_true()
  list.contains(table_names, "comments") |> should.be_true()
  list.contains(table_names, "tags") |> should.be_true()
  list.contains(table_names, "post_tags") |> should.be_true()
}

pub fn complex_schema_column_types_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")

  let assert Ok(users) = list.find(catalog.tables, fn(t) { t.name == "users" })
  let assert [id, username, email, is_active, created_at, profile_image] =
    users.columns

  id.scalar_type |> should.equal(model.IntType)
  username.scalar_type |> should.equal(model.StringType)
  email.scalar_type |> should.equal(model.StringType)
  is_active.scalar_type |> should.equal(model.BoolType)
  created_at.scalar_type |> should.equal(model.DateTimeType)
  profile_image.scalar_type |> should.equal(model.BytesType)
  profile_image.nullable |> should.equal(True)
}

pub fn complex_schema_nullable_foreign_keys_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")

  let assert Ok(posts) = list.find(catalog.tables, fn(t) { t.name == "posts" })
  let assert Ok(category_id) =
    list.find(posts.columns, fn(c) { c.name == "category_id" })
  // category_id is nullable (no NOT NULL)
  category_id.nullable |> should.equal(True)

  let assert Ok(author_id) =
    list.find(posts.columns, fn(c) { c.name == "author_id" })
  // author_id is NOT NULL
  author_id.nullable |> should.equal(False)
}

// ============================================================
// Complex queries: JOINs, RETURNING, UPDATE, DELETE
// ============================================================

pub fn complex_query_basic_crud_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // GetPost :one - should have result columns
  let assert Ok(get_post) =
    list.find(analyzed, fn(q) { q.base.name == "GetPost" })
  get_post.base.command |> should.equal(runtime.QueryOne)
  list.length(get_post.result_columns) |> should.equal(4)
  let assert [id, title, body, published] = get_post.result_columns
  let assert model.ResultColumn(scalar_type: id_type, ..) = id
  id_type |> should.equal(model.IntType)
  let assert model.ResultColumn(scalar_type: title_type, ..) = title
  title_type |> should.equal(model.StringType)
  let assert model.ResultColumn(scalar_type: body_type, ..) = body
  body_type |> should.equal(model.StringType)
  let assert model.ResultColumn(scalar_type: published_type, ..) = published
  published_type |> should.equal(model.BoolType)

  // CreatePost :exec - no result columns
  let assert Ok(create_post) =
    list.find(analyzed, fn(q) { q.base.name == "CreatePost" })
  create_post.base.command |> should.equal(runtime.QueryExec)
  create_post.result_columns |> should.equal([])
  create_post.base.param_count |> should.equal(8)

  // DeletePost :exec
  let assert Ok(delete_post) =
    list.find(analyzed, fn(q) { q.base.name == "DeletePost" })
  delete_post.base.command |> should.equal(runtime.QueryExec)
  delete_post.base.param_count |> should.equal(1)
}

pub fn complex_query_single_join_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(post_with_author) =
    list.find(analyzed, fn(q) { q.base.name == "GetPostWithAuthor" })
  list.length(post_with_author.result_columns) |> should.equal(2)

  let assert [title, username] = post_with_author.result_columns
  title.name |> should.equal("title")
  let assert model.ResultColumn(scalar_type: title_type, ..) = title
  title_type |> should.equal(model.StringType)
  username.name |> should.equal("username")
  let assert model.ResultColumn(scalar_type: username_type, ..) = username
  username_type |> should.equal(model.StringType)
}

pub fn complex_query_multi_join_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(post_full) =
    list.find(analyzed, fn(q) { q.base.name == "GetPostWithAuthorAndCategory" })
  list.length(post_full.result_columns) |> should.equal(3)

  let assert [title, username, cat_name] = post_full.result_columns
  title.name |> should.equal("title")
  username.name |> should.equal("username")
  cat_name.name |> should.equal("name")
}

pub fn complex_query_returning_clause_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // INSERT ... RETURNING
  let assert Ok(create_returning) =
    list.find(analyzed, fn(q) { q.base.name == "CreatePostReturning" })
  create_returning.base.command |> should.equal(runtime.QueryOne)
  list.length(create_returning.result_columns) |> should.equal(2)
  let assert [id, title] = create_returning.result_columns
  id.name |> should.equal("id")
  let assert model.ResultColumn(scalar_type: id_type, ..) = id
  id_type |> should.equal(model.IntType)
  title.name |> should.equal("title")

  // DELETE ... RETURNING
  let assert Ok(delete_returning) =
    list.find(analyzed, fn(q) { q.base.name == "DeletePostReturning" })
  delete_returning.base.command |> should.equal(runtime.QueryOne)
  list.length(delete_returning.result_columns) |> should.equal(2)

  // UPDATE ... RETURNING
  let assert Ok(update_returning) =
    list.find(analyzed, fn(q) { q.base.name == "UpdatePostReturning" })
  update_returning.base.command |> should.equal(runtime.QueryOne)
  list.length(update_returning.result_columns) |> should.equal(3)
  let assert [_, _, published] = update_returning.result_columns
  published.name |> should.equal("published")
  let assert model.ResultColumn(scalar_type: published_type, ..) = published
  published_type |> should.equal(model.BoolType)
}

pub fn complex_query_update_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(update) =
    list.find(analyzed, fn(q) { q.base.name == "UpdatePostTitle" })
  update.base.param_count |> should.equal(2)
  list.length(update.params) |> should.equal(2)
}

// ============================================================
// sqlc macro edge cases
// ============================================================

pub fn macro_duplicate_arg_name_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(search) =
    list.find(queries, fn(q) { q.name == "SearchByNameOrBio" })
  // Two sqlode.arg(search_term) should produce two separate placeholders
  search.param_count |> should.equal(2)
  list.length(search.macros) |> should.equal(2)
}

pub fn macro_mixed_arg_narg_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(insert) =
    list.find(analyzed, fn(q) { q.base.name == "InsertWithMixedMacros" })
  let assert [name_param, bio_param] = insert.params
  name_param.field_name |> should.equal("author_name")
  name_param.nullable |> should.equal(False)
  bio_param.field_name |> should.equal("author_bio")
  bio_param.nullable |> should.equal(True)
}

pub fn macro_slice_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(get_by_ids) =
    list.find(analyzed, fn(q) { q.base.name == "GetByMultipleIds" })
  let assert [param] = get_by_ids.params
  param.field_name |> should.equal("ids")
  param.is_list |> should.equal(True)
}

pub fn macro_update_with_multiple_macros_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(update) =
    list.find(analyzed, fn(q) { q.base.name == "UpdateWithNarg" })
  list.length(update.params) |> should.equal(3)

  let assert [name_param, bio_param, id_param] = update.params
  name_param.field_name |> should.equal("new_name")
  name_param.nullable |> should.equal(False)
  bio_param.field_name |> should.equal("new_bio")
  bio_param.nullable |> should.equal(True)
  id_param.field_name |> should.equal("author_id")
  id_param.nullable |> should.equal(False)
}

// ============================================================
// sqlc-compatible E2E: common SQL patterns
// ============================================================

pub fn create_index_ignored_gracefully_test() {
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")

  // CREATE INDEX should be silently ignored; only tables are parsed
  let table_names = list.map(catalog.tables, fn(t) { t.name })
  list.contains(table_names, "users") |> should.be_true()
  list.contains(table_names, "posts") |> should.be_true()
  list.contains(table_names, "tags") |> should.be_true()
  list.contains(table_names, "post_tags") |> should.be_true()
  // No extra tables from CREATE INDEX
  list.length(catalog.tables) |> should.equal(4)
}

pub fn foreign_key_on_delete_cascade_test() {
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")

  // Foreign key constraints with ON DELETE CASCADE should not break parsing
  let assert Ok(posts) = list.find(catalog.tables, fn(t) { t.name == "posts" })
  let assert Ok(user_id_col) =
    list.find(posts.columns, fn(c) { c.name == "user_id" })
  user_id_col.scalar_type |> should.equal(model.IntType)
  user_id_col.nullable |> should.equal(False)
}

pub fn numeric_precision_test() {
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")

  let assert Ok(users) = list.find(catalog.tables, fn(t) { t.name == "users" })
  let assert Ok(score_col) =
    list.find(users.columns, fn(c) { c.name == "score" })
  score_col.scalar_type |> should.equal(model.FloatType)
  score_col.nullable |> should.equal(False)
}

pub fn upsert_on_conflict_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(upsert) = list.find(queries, fn(q) { q.name == "UpsertUser" })
  upsert.command |> should.equal(runtime.QueryOne)
  upsert.param_count |> should.equal(2)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert Ok(upsert_a) =
    list.find(analyzed, fn(q) { q.base.name == "UpsertUser" })
  // RETURNING id, email, name → 3 result columns
  list.length(upsert_a.result_columns) |> should.equal(3)
  list.length(upsert_a.params) |> should.equal(2)
}

pub fn distinct_query_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(distinct) =
    list.find(queries, fn(q) { q.name == "ListPostsByTag" })
  distinct.command |> should.equal(runtime.QueryMany)
  distinct.param_count |> should.equal(1)
}

pub fn group_by_having_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(grouped) =
    list.find(queries, fn(q) { q.name == "ListActiveUsers" })
  grouped.command |> should.equal(runtime.QueryMany)
  grouped.param_count |> should.equal(1)
}

pub fn exists_subquery_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(with_posts) =
    list.find(queries, fn(q) { q.name == "ListUsersWithPosts" })
  with_posts.command |> should.equal(runtime.QueryMany)
  // No params in the outer query (subquery is correlated, not parameterized)
  with_posts.param_count |> should.equal(0)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert Ok(with_posts_a) =
    list.find(analyzed, fn(q) { q.base.name == "ListUsersWithPosts" })
  list.length(with_posts_a.result_columns) |> should.equal(2)
}

pub fn not_exists_subquery_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(without_posts) =
    list.find(queries, fn(q) { q.name == "ListUsersWithoutPosts" })
  without_posts.command |> should.equal(runtime.QueryMany)
  without_posts.param_count |> should.equal(0)
}

pub fn parameterized_pagination_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/sqlc_compat/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(paginate) =
    list.find(queries, fn(q) { q.name == "PaginateUsers" })
  paginate.command |> should.equal(runtime.QueryMany)
  paginate.param_count |> should.equal(2)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert Ok(paginate_a) =
    list.find(analyzed, fn(q) { q.base.name == "PaginateUsers" })
  list.length(paginate_a.result_columns) |> should.equal(3)
}

pub fn multiple_ctes_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(multi_cte) =
    list.find(queries, fn(q) { q.name == "RecentPostsWithAuthor" })
  multi_cte.command |> should.equal(runtime.QueryMany)
  // No parameters in this query
  multi_cte.param_count |> should.equal(0)
}

pub fn distinct_top_scores_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/sqlc_compat/queries.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(top) =
    list.find(queries, fn(q) { q.name == "TopDistinctScores" })
  top.command |> should.equal(runtime.QueryMany)
  top.param_count |> should.equal(1)
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
