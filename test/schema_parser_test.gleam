import gleam/list
import gleam/string
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
  let assert Ok(#(catalog, _)) =
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

pub fn parse_extended_types_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/extended_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/extended_schema.sql", content),
    ])

  let assert [table] = catalog.tables
  table.name |> should.equal("events")
  list.length(table.columns) |> should.equal(8)

  let assert [
    id,
    title,
    description,
    event_date,
    start_time,
    created_at,
    metadata,
    external_id,
  ] = table.columns

  id.scalar_type |> should.equal(model.IntType)
  title.scalar_type |> should.equal(model.StringType)
  description.nullable |> should.equal(True)
  event_date.scalar_type |> should.equal(model.DateType)
  start_time.scalar_type |> should.equal(model.TimeType)
  created_at.scalar_type |> should.equal(model.DateTimeType)
  metadata.scalar_type |> should.equal(model.JsonType)
  metadata.nullable |> should.equal(True)
  external_id.scalar_type |> should.equal(model.UuidType)
  external_id.nullable |> should.equal(False)
}

// Error and boundary tests

pub fn empty_schema_content_test() {
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("empty.sql", "")])
  catalog.tables |> should.equal([])
}

pub fn schema_with_only_whitespace_test() {
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("blank.sql", "   \n  \n  ")])
  catalog.tables |> should.equal([])
}

pub fn schema_with_comments_only_test() {
  let content = "-- This is a comment\n-- Another comment\n"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("comments.sql", content)])
  catalog.tables |> should.equal([])
}

pub fn schema_missing_parenthesis_test() {
  let content = "CREATE TABLE broken name TEXT NOT NULL;"
  let assert Error(error) =
    schema_parser.parse_files([#("broken.sql", content)])
  let msg = schema_parser.error_to_string(error)
  string.contains(msg, "parenthesis") |> should.be_true()
}

pub fn schema_if_not_exists_test() {
  let content =
    "CREATE TABLE IF NOT EXISTS users (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL\n"
    <> ");"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("ifne.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
  list.length(table.columns) |> should.equal(2)
}

pub fn schema_quoted_table_name_test() {
  let content =
    "CREATE TABLE \"MyTable\" (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL\n"
    <> ");"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("quoted.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("mytable")
}

pub fn schema_multiple_files_test() {
  let file1 = "CREATE TABLE a (id BIGSERIAL PRIMARY KEY);"
  let file2 = "CREATE TABLE b (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("a.sql", file1), #("b.sql", file2)])
  list.length(catalog.tables) |> should.equal(2)
}

pub fn schema_table_with_constraints_test() {
  let content =
    "CREATE TABLE orders (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  user_id BIGINT NOT NULL,\n"
    <> "  total NUMERIC(10,2) NOT NULL,\n"
    <> "  FOREIGN KEY (user_id) REFERENCES users(id)\n"
    <> ");"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("fk.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("orders")
  // FOREIGN KEY constraint should not be parsed as a column
  list.length(table.columns) |> should.equal(3)
}

pub fn schema_enum_type_test() {
  let content =
    "CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral');\n"
    <> "CREATE TABLE people (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  current_mood mood NOT NULL\n"
    <> ");"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("enum.sql", content)])
  let assert [enum] = catalog.enums
  enum.name |> should.equal("mood")
  enum.values |> should.equal(["happy", "sad", "neutral"])

  let assert [table] = catalog.tables
  let assert Ok(mood_col) =
    list.find(table.columns, fn(c) { c.name == "current_mood" })
  mood_col.scalar_type |> should.equal(model.EnumType("mood"))
}

pub fn view_with_cast_expression_test() {
  let content =
    "CREATE TABLE t (x TEXT NOT NULL, y TEXT NOT NULL);\n"
    <> "CREATE VIEW v AS SELECT CAST(x AS TEXT) AS col_a, y AS col_b FROM t;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("cast_view.sql", content)])

  let assert Ok(view) = list.find(catalog.tables, fn(tbl) { tbl.name == "v" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["col_a", "col_b"])

  let assert Ok(col_a) = list.find(view.columns, fn(c) { c.name == "col_a" })
  col_a.scalar_type |> should.equal(model.StringType)

  let assert Ok(col_b) = list.find(view.columns, fn(c) { c.name == "col_b" })
  col_b.scalar_type |> should.equal(model.StringType)
}

pub fn view_basic_select_test() {
  let content =
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT);\n"
    <> "CREATE VIEW active_users AS SELECT id, name FROM users;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "active_users" })
  list.length(view.columns) |> should.equal(2)
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["id", "name"])
}

pub fn view_with_alias_test() {
  let content =
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);\n"
    <> "CREATE VIEW user_names AS SELECT id, name AS display_name FROM users;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("view_alias.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "user_names" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["id", "display_name"])

  let assert Ok(display) =
    list.find(view.columns, fn(c) { c.name == "display_name" })
  display.scalar_type |> should.equal(model.StringType)
  display.nullable |> should.be_false
}

pub fn view_star_test() {
  let content =
    "CREATE TABLE items (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);\n"
    <> "CREATE VIEW all_items AS SELECT * FROM items;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("view_star.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "all_items" })
  list.length(view.columns) |> should.equal(2)
}

pub fn view_or_replace_test() {
  let content =
    "CREATE TABLE t (id BIGSERIAL PRIMARY KEY, val TEXT NOT NULL);\n"
    <> "CREATE OR REPLACE VIEW v AS SELECT id FROM t;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("or_replace.sql", content)])

  let assert Ok(view) = list.find(catalog.tables, fn(tbl) { tbl.name == "v" })
  list.length(view.columns) |> should.equal(1)
}

pub fn view_nonexistent_table_test() {
  let content = "CREATE VIEW v AS SELECT id FROM nonexistent;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("noexist.sql", content)])

  // View referencing nonexistent table: all columns are unresolvable and
  // skipped, so the view itself is omitted (no columns → no table entry).
  let view_found = list.find(catalog.tables, fn(tbl) { tbl.name == "v" })
  view_found |> should.be_error()
}

pub fn error_to_string_invalid_column_test() {
  schema_parser.error_to_string(schema_parser.InvalidColumn(
    table: "users",
    detail: "missing type",
  ))
  |> string.contains("users")
  |> should.be_true()
}

pub fn unrecognized_sql_type_returns_error_test() {
  let content =
    "CREATE TABLE geo (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  shape GEOMETRY NOT NULL\n"
    <> ");"
  let assert Error(error) = schema_parser.parse_files([#("geo.sql", content)])
  let msg = schema_parser.error_to_string(error)
  string.contains(msg, "geo") |> should.be_true()
  string.contains(msg, "GEOMETRY") |> should.be_true()
  string.contains(msg, "Hint:") |> should.be_true()
  string.contains(msg, "Supported types:") |> should.be_true()
}

// --- ALTER TABLE ADD COLUMN tests ---

pub fn alter_table_add_column_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
ALTER TABLE users ADD COLUMN email TEXT;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
  list.length(table.columns) |> should.equal(3)
  let assert [_, _, email] = table.columns
  email.name |> should.equal("email")
  email.scalar_type |> should.equal(model.StringType)
  email.nullable |> should.equal(True)
}

pub fn alter_table_add_column_with_keyword_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY);
ALTER TABLE users ADD COLUMN status TEXT NOT NULL;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(2)
  let assert [_, status] = table.columns
  status.name |> should.equal("status")
  status.nullable |> should.equal(False)
}

pub fn alter_table_add_without_column_keyword_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY);
ALTER TABLE users ADD bio TEXT;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(2)
  let assert [_, bio] = table.columns
  bio.name |> should.equal("bio")
}

pub fn alter_table_add_column_nonexistent_table_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY);
ALTER TABLE posts ADD COLUMN title TEXT;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  // posts table does not exist, so ALTER TABLE is silently ignored
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
  list.length(table.columns) |> should.equal(1)
}

pub fn alter_table_add_constraint_ignored_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);
ALTER TABLE users ADD CONSTRAINT unique_email UNIQUE (email);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  // ADD CONSTRAINT should not add a column
  list.length(table.columns) |> should.equal(2)
}

pub fn view_with_count_expression_test() {
  let content =
    "CREATE TABLE authors (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);\n"
    <> "CREATE VIEW author_counts AS SELECT COUNT(*) AS total FROM authors;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("count_view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "author_counts" })
  let assert Ok(total) = list.find(view.columns, fn(c) { c.name == "total" })
  total.scalar_type |> should.equal(model.IntType)
  total.nullable |> should.be_false
}

pub fn view_with_sum_expression_test() {
  let content =
    "CREATE TABLE orders (id BIGSERIAL PRIMARY KEY, amount INTEGER NOT NULL);\n"
    <> "CREATE VIEW order_totals AS SELECT SUM(amount) AS total_amount FROM orders;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("sum_view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "order_totals" })
  let assert Ok(total) =
    list.find(view.columns, fn(c) { c.name == "total_amount" })
  total.scalar_type |> should.equal(model.IntType)
  total.nullable |> should.be_true
}

pub fn view_with_avg_expression_test() {
  let content =
    "CREATE TABLE products (id BIGSERIAL PRIMARY KEY, price REAL NOT NULL);\n"
    <> "CREATE VIEW avg_prices AS SELECT AVG(price) AS avg_price FROM products;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("avg_view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "avg_prices" })
  let assert Ok(avg) = list.find(view.columns, fn(c) { c.name == "avg_price" })
  avg.scalar_type |> should.equal(model.FloatType)
  avg.nullable |> should.be_true
}

pub fn view_with_coalesce_expression_test() {
  let content =
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, bio TEXT);\n"
    <> "CREATE VIEW user_display AS SELECT id, COALESCE(bio, 'N/A') AS bio_text FROM users;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("coalesce_view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "user_display" })
  let assert Ok(bio) = list.find(view.columns, fn(c) { c.name == "bio_text" })
  bio.scalar_type |> should.equal(model.StringType)
  bio.nullable |> should.be_false
}

pub fn view_with_literal_expression_test() {
  let content =
    "CREATE TABLE t (id BIGSERIAL PRIMARY KEY);\n"
    <> "CREATE VIEW v AS SELECT 42 AS magic, 'hello' AS greeting FROM t;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("literal_view.sql", content)])

  let assert Ok(view) = list.find(catalog.tables, fn(tbl) { tbl.name == "v" })
  let assert Ok(magic) = list.find(view.columns, fn(c) { c.name == "magic" })
  magic.scalar_type |> should.equal(model.IntType)

  let assert Ok(greeting) =
    list.find(view.columns, fn(c) { c.name == "greeting" })
  greeting.scalar_type |> should.equal(model.StringType)
}

pub fn serial_types_are_implicitly_not_null_test() {
  let content =
    "CREATE TABLE t (\n"
    <> "  a SERIAL,\n"
    <> "  b BIGSERIAL,\n"
    <> "  c SMALLSERIAL,\n"
    <> "  d INTEGER\n"
    <> ");\n"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("serial.sql", content)])

  let assert [table] = catalog.tables
  let assert [a, b, c, d] = table.columns

  // SERIAL/BIGSERIAL/SMALLSERIAL should be implicitly NOT NULL
  a.nullable |> should.equal(False)
  b.nullable |> should.equal(False)
  c.nullable |> should.equal(False)
  // Plain INTEGER without NOT NULL should be nullable
  d.nullable |> should.equal(True)
}

pub fn view_with_join_extracts_all_source_tables_test() {
  let content =
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);\n"
    <> "CREATE TABLE orders (id BIGSERIAL PRIMARY KEY, user_id INTEGER NOT NULL, amount INTEGER NOT NULL);\n"
    <> "CREATE VIEW user_orders AS SELECT u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id;\n"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("join_view.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "user_orders" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["name", "amount"])

  let assert Ok(name_col) = list.find(view.columns, fn(c) { c.name == "name" })
  name_col.scalar_type |> should.equal(model.StringType)

  let assert Ok(amount_col) =
    list.find(view.columns, fn(c) { c.name == "amount" })
  amount_col.scalar_type |> should.equal(model.IntType)
}

pub fn view_with_left_join_test() {
  let content =
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);\n"
    <> "CREATE TABLE profiles (id BIGSERIAL PRIMARY KEY, user_id INTEGER NOT NULL, bio TEXT);\n"
    <> "CREATE VIEW user_profiles AS SELECT u.name, p.bio FROM users u LEFT JOIN profiles p ON u.id = p.user_id;\n"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("left_join.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "user_profiles" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["name", "bio"])
}

pub fn view_star_with_join_test() {
  let content =
    "CREATE TABLE t1 (a INTEGER NOT NULL, b TEXT NOT NULL);\n"
    <> "CREATE TABLE t2 (c INTEGER NOT NULL, d TEXT NOT NULL);\n"
    <> "CREATE VIEW v AS SELECT * FROM t1 JOIN t2 ON t1.a = t2.c;\n"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("star_join.sql", content)])

  let assert Ok(view) = list.find(catalog.tables, fn(tbl) { tbl.name == "v" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["a", "b", "c", "d"])
}

// --- Malformed DDL robustness ---

pub fn schema_empty_input_produces_empty_catalog_test() {
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("empty.sql", "")])
  catalog.tables |> should.equal([])
  catalog.enums |> should.equal([])
}

pub fn schema_truncated_create_table_test() {
  let assert Error(_) =
    schema_parser.parse_files([#("trunc.sql", "CREATE TABLE")])
}

pub fn schema_only_keyword_create_does_not_panic_test() {
  // "CREATE" alone is not a recognized DDL statement; the parser should
  // silently produce an empty catalog rather than panic.
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("create.sql", "CREATE")])
  catalog.tables |> should.equal([])
}

pub fn schema_duplicate_table_across_files_test() {
  // Current behavior: both definitions are kept, last one wins during
  // column lookup (list.find takes first match but append order makes the
  // earlier file's table be found first). Whatever the exact semantics,
  // the parser should not panic and the catalog should contain entries.
  let file1 = "CREATE TABLE shared (id BIGSERIAL PRIMARY KEY);"
  let file2 =
    "CREATE TABLE shared (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("one.sql", file1), #("two.sql", file2)])
  // Both definitions currently coexist — this test pins the behavior so
  // future changes (dedup, error, or merge) surface as a test failure.
  list.length(catalog.tables) |> should.equal(2)
}
