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
    "CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL
);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("ifne.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
  list.length(table.columns) |> should.equal(2)
}

pub fn schema_quoted_table_name_test() {
  let content =
    "CREATE TABLE \"MyTable\" (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL
);"
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
    "CREATE TABLE orders (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  total NUMERIC(10,2) NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("fk.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("orders")
  // FOREIGN KEY constraint should not be parsed as a column
  list.length(table.columns) |> should.equal(3)
}

pub fn schema_enum_type_test() {
  let content =
    "CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral');
CREATE TABLE people (
  id BIGSERIAL PRIMARY KEY,
  current_mood mood NOT NULL
);"
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

pub fn mysql_inline_enum_and_set_columns_test() {
  // Issue #407 / #420: MySQL `CREATE TABLE` may declare ENUM / SET
  // inline on a column. The parser preserves the allowed values in
  // the catalog and surfaces ENUM as `EnumType(name)` and SET as
  // first-class `SetType(name)` (no longer a StringType fallback).
  let content =
    "CREATE TABLE items (
  id BIGINT NOT NULL,
  status ENUM('active', 'inactive', 'archived') NOT NULL,
  tags SET('red', 'green', 'blue')
);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("items.sql", content)],
      model.MySQL,
    )

  let assert [table] = catalog.tables
  table.name |> should.equal("items")

  let assert Ok(status_col) =
    list.find(table.columns, fn(c) { c.name == "status" })
  status_col.scalar_type |> should.equal(model.EnumType("items_status"))
  status_col.nullable |> should.equal(False)

  let assert Ok(tags_col) = list.find(table.columns, fn(c) { c.name == "tags" })
  tags_col.scalar_type |> should.equal(model.SetType("items_tags"))

  let assert Ok(status_enum) =
    list.find(catalog.enums, fn(e) { e.name == "items_status" })
  status_enum.values |> should.equal(["active", "inactive", "archived"])
  status_enum.kind |> should.equal(model.MySqlEnum)

  let assert Ok(tags_enum) =
    list.find(catalog.enums, fn(e) { e.name == "items_tags" })
  tags_enum.values |> should.equal(["red", "green", "blue"])
  tags_enum.kind |> should.equal(model.MySqlSet)
}

pub fn view_with_cast_expression_test() {
  let content =
    "CREATE TABLE t (x TEXT NOT NULL, y TEXT NOT NULL);
CREATE VIEW v AS SELECT CAST(x AS TEXT) AS col_a, y AS col_b FROM t;"
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
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT);
CREATE VIEW active_users AS SELECT id, name FROM users;"
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
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE VIEW user_names AS SELECT id, name AS display_name FROM users;"
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
    "CREATE TABLE items (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE VIEW all_items AS SELECT * FROM items;"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("view_star.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "all_items" })
  list.length(view.columns) |> should.equal(2)
}

pub fn view_or_replace_test() {
  let content =
    "CREATE TABLE t (id BIGSERIAL PRIMARY KEY, val TEXT NOT NULL);
CREATE OR REPLACE VIEW v AS SELECT id FROM t;"
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
    path: "schema.sql",
    table: "users",
    detail: "missing type",
  ))
  |> string.contains("users")
  |> should.be_true()
}

pub fn error_to_string_includes_path_test() {
  schema_parser.error_to_string(schema_parser.InvalidColumn(
    path: "db/schema.sql",
    table: "users",
    detail: "missing type",
  ))
  |> string.contains("db/schema.sql")
  |> should.be_true()
}

pub fn parse_error_carries_source_path_test() {
  // Truncated CREATE TABLE surfaces with the originating file path so
  // users with multiple schema files can locate the issue.
  let assert Error(err) =
    schema_parser.parse_files([#("db/main.sql", "CREATE TABLE")])
  case err {
    schema_parser.InvalidCreateTable(path:, ..) ->
      path |> should.equal("db/main.sql")
    _ -> should.fail()
  }
}

pub fn unrecognized_sql_type_returns_error_test() {
  let content =
    "CREATE TABLE geo (
  id BIGSERIAL PRIMARY KEY,
  shape GEOMETRY NOT NULL
);"
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
    "CREATE TABLE authors (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE VIEW author_counts AS SELECT COUNT(*) AS total FROM authors;"
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
    "CREATE TABLE orders (id BIGSERIAL PRIMARY KEY, amount INTEGER NOT NULL);
CREATE VIEW order_totals AS SELECT SUM(amount) AS total_amount FROM orders;"
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
    "CREATE TABLE products (id BIGSERIAL PRIMARY KEY, price REAL NOT NULL);
CREATE VIEW avg_prices AS SELECT AVG(price) AS avg_price FROM products;"
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
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, bio TEXT);
CREATE VIEW user_display AS SELECT id, COALESCE(bio, 'N/A') AS bio_text FROM users;"
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
    "CREATE TABLE t (id BIGSERIAL PRIMARY KEY);
CREATE VIEW v AS SELECT 42 AS magic, 'hello' AS greeting FROM t;"
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
    "CREATE TABLE t (
  a SERIAL,
  b BIGSERIAL,
  c SMALLSERIAL,
  d INTEGER
);
"

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
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE orders (id BIGSERIAL PRIMARY KEY, user_id INTEGER NOT NULL, amount INTEGER NOT NULL);
CREATE VIEW user_orders AS SELECT u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id;
"

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
    "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE profiles (id BIGSERIAL PRIMARY KEY, user_id INTEGER NOT NULL, bio TEXT);
CREATE VIEW user_profiles AS SELECT u.name, p.bio FROM users u LEFT JOIN profiles p ON u.id = p.user_id;
"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("left_join.sql", content)])

  let assert Ok(view) =
    list.find(catalog.tables, fn(tbl) { tbl.name == "user_profiles" })
  let col_names = list.map(view.columns, fn(c) { c.name })
  col_names |> should.equal(["name", "bio"])
}

pub fn view_star_with_join_test() {
  let content =
    "CREATE TABLE t1 (a INTEGER NOT NULL, b TEXT NOT NULL);
CREATE TABLE t2 (c INTEGER NOT NULL, d TEXT NOT NULL);
CREATE VIEW v AS SELECT * FROM t1 JOIN t2 ON t1.a = t2.c;
"

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

// --- Batch 6: DDL extensions (CHECK, GENERATED, INDEX, composite keys,
//     PARTITION, MySQL ON UPDATE) ---
//
// These constructs add metadata that codegen does not consume. The
// requirement is that they parse without losing the column types or
// erroring on the table.

pub fn check_constraint_inline_test() {
  let sql =
    "CREATE TABLE products (id INT PRIMARY KEY, price NUMERIC NOT NULL CHECK (price > 0));"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("p.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("products")
  let assert [id, price] = table.columns
  id.scalar_type |> should.equal(model.IntType)
  price.scalar_type |> should.equal(model.FloatType)
  price.nullable |> should.equal(False)
}

pub fn check_constraint_table_level_test() {
  // Table-level CHECK is its own pseudo-column entry; parser must
  // skip it without dropping the real columns.
  let sql =
    "CREATE TABLE orders (id INT, qty INT, price NUMERIC, CHECK (qty > 0 AND price > 0));"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("o.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(3)
}

pub fn composite_primary_key_test() {
  let sql =
    "CREATE TABLE memberships (user_id INT, group_id INT, joined_at TIMESTAMP, PRIMARY KEY (user_id, group_id));"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("m.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(3)
  let assert [user_id, group_id, _joined] = table.columns
  user_id.name |> should.equal("user_id")
  group_id.name |> should.equal("group_id")
}

pub fn composite_foreign_key_test() {
  let sql =
    "CREATE TABLE orders (id INT PRIMARY KEY, customer_region INT, customer_id INT, FOREIGN KEY (customer_region, customer_id) REFERENCES customers (region, id) ON DELETE CASCADE);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("fk.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(3)
}

pub fn generated_column_stored_test() {
  // Generated column types are still inferred from the declared type
  // (INT here); the GENERATED ALWAYS AS (...) STORED expression is
  // metadata that codegen does not consume.
  let sql =
    "CREATE TABLE invoices (qty INT, price NUMERIC, total NUMERIC GENERATED ALWAYS AS (qty * price) STORED);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("i.sql", sql)])
  let assert [table] = catalog.tables
  let assert [qty, price, total] = table.columns
  qty.scalar_type |> should.equal(model.IntType)
  price.scalar_type |> should.equal(model.FloatType)
  total.scalar_type |> should.equal(model.FloatType)
}

pub fn mysql_on_update_current_timestamp_test() {
  // MySQL `ON UPDATE CURRENT_TIMESTAMP` is a DEFAULT-style modifier;
  // the column type (DATETIME → DateTimeType) must still be picked up.
  let sql =
    "CREATE TABLE entries (id INT PRIMARY KEY, updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("r.sql", sql)])
  let assert [table] = catalog.tables
  let assert [_id, updated] = table.columns
  updated.scalar_type |> should.equal(model.DateTimeType)
  updated.nullable |> should.equal(False)
}

pub fn create_index_is_skipped_test() {
  // CREATE INDEX must not produce a phantom table or break the
  // parser when followed by a real CREATE TABLE.
  let sql =
    "CREATE INDEX idx_authors_name ON authors(name); CREATE TABLE authors (id INT PRIMARY KEY, name TEXT NOT NULL);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("idx.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("authors")
  list.length(table.columns) |> should.equal(2)
}

pub fn create_unique_index_is_skipped_test() {
  let sql =
    "CREATE UNIQUE INDEX idx_authors_name ON authors(name); CREATE TABLE authors (id INT PRIMARY KEY, name TEXT NOT NULL);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("uidx.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("authors")
}

pub fn partition_by_clause_does_not_break_table_test() {
  let sql =
    "CREATE TABLE measurements (id INT, ts TIMESTAMP NOT NULL, value NUMERIC) PARTITION BY RANGE (ts);"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("part.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("measurements")
  list.length(table.columns) |> should.equal(3)
}

// Unsupported-DDL diagnostics (Issue #362)

pub fn drop_table_removes_table_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
DROP TABLE users;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  list.length(catalog.tables) |> should.equal(0)
}

pub fn drop_table_if_exists_nonexistent_test() {
  let sql = "DROP TABLE IF EXISTS users;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  list.length(catalog.tables) |> should.equal(0)
}

pub fn drop_view_removes_view_test() {
  let sql =
    "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE VIEW author_list AS SELECT id, name FROM authors;
DROP VIEW author_list;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  list.length(catalog.tables) |> should.equal(1)
  let assert [table] = catalog.tables
  table.name |> should.equal("authors")
}

pub fn drop_type_removes_enum_test() {
  let sql =
    "CREATE TYPE status AS ENUM ('active', 'inactive');
DROP TYPE status;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  list.length(catalog.enums) |> should.equal(0)
}

pub fn alter_table_drop_column_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
ALTER TABLE users DROP COLUMN name;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(1)
  let assert [col] = table.columns
  col.name |> should.equal("id")
}

pub fn alter_table_if_exists_drop_column_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
ALTER TABLE IF EXISTS users DROP COLUMN name;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(1)
}

pub fn alter_table_rename_column_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
ALTER TABLE users RENAME COLUMN name TO full_name;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  let assert [_, col2] = table.columns
  col2.name |> should.equal("full_name")
}

pub fn alter_table_rename_to_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY);
ALTER TABLE users RENAME TO accounts;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("accounts")
}

pub fn alter_table_set_not_null_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, created_at TIMESTAMP);
ALTER TABLE users ALTER COLUMN created_at SET NOT NULL;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  let assert [_, col2] = table.columns
  col2.name |> should.equal("created_at")
  col2.nullable |> should.equal(False)
}

pub fn alter_table_drop_not_null_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
ALTER TABLE users ALTER COLUMN name DROP NOT NULL;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  let assert [_, col2] = table.columns
  col2.name |> should.equal("name")
  col2.nullable |> should.equal(True)
}

pub fn alter_table_alter_column_type_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, score INTEGER NOT NULL);
ALTER TABLE users ALTER COLUMN score TYPE TEXT;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  let assert [_, col2] = table.columns
  col2.name |> should.equal("score")
  col2.scalar_type |> should.equal(model.StringType)
}

pub fn alter_table_drop_constraint_stays_silent_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
ALTER TABLE users DROP CONSTRAINT unique_email;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  list.length(table.columns) |> should.equal(2)
}

pub fn comment_on_stays_silent_test() {
  let sql =
    "CREATE TABLE users (id INTEGER PRIMARY KEY);
COMMENT ON TABLE users IS 'account records';"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
}

pub fn transaction_control_stays_silent_test() {
  let sql = "BEGIN;\nCREATE TABLE users (id INTEGER PRIMARY KEY);\nCOMMIT;"
  let assert Ok(#(catalog, _)) = schema_parser.parse_files([#("test.sql", sql)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
}

// Issue #419: MySQL migration history tests. The same logical schema
// expressed as either a multi-step migration or a single snapshot must
// resolve to the same final catalog.

pub fn mysql_migration_history_resolves_to_expected_catalog_test() {
  let assert Ok(create) =
    simplifile.read("test/fixtures/mysql_migration_001_create_authors.sql")
  let assert Ok(alter) =
    simplifile.read("test/fixtures/mysql_migration_002_alter_authors.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [
        #("001_create_authors.sql", create),
        #("002_alter_authors.sql", alter),
      ],
      model.MySQL,
    )

  let assert [table] = catalog.tables
  table.name |> should.equal("authors")

  let column_names = list.map(table.columns, fn(c) { c.name })
  column_names
  |> should.equal(["id", "email", "name", "bio", "created_at", "updated_at"])

  let assert Ok(bio_col) = list.find(table.columns, fn(c) { c.name == "bio" })
  bio_col.scalar_type |> should.equal(model.StringType)
  bio_col.nullable |> should.be_true()
}

pub fn mysql_snapshot_matches_migration_history_test() {
  let assert Ok(create) =
    simplifile.read("test/fixtures/mysql_migration_001_create_authors.sql")
  let assert Ok(alter) =
    simplifile.read("test/fixtures/mysql_migration_002_alter_authors.sql")
  let assert Ok(snapshot) =
    simplifile.read("test/fixtures/mysql_snapshot_authors.sql")

  let assert Ok(#(history_catalog, _)) =
    schema_parser.parse_files_with_engine(
      [
        #("001_create_authors.sql", create),
        #("002_alter_authors.sql", alter),
      ],
      model.MySQL,
    )
  let assert Ok(#(snapshot_catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("snapshot.sql", snapshot)],
      model.MySQL,
    )

  let history_columns =
    history_catalog.tables
    |> list.flat_map(fn(t) { list.map(t.columns, fn(c) { c.name }) })
  let snapshot_columns =
    snapshot_catalog.tables
    |> list.flat_map(fn(t) { list.map(t.columns, fn(c) { c.name }) })
  history_columns |> should.equal(snapshot_columns)
}

pub fn mysql_alter_modify_changes_column_type_test() {
  let create =
    "CREATE TABLE `events` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `payload` TEXT NULL,
  PRIMARY KEY (`id`)
);
ALTER TABLE `events` MODIFY COLUMN `payload` JSON NOT NULL;"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("events.sql", create)],
      model.MySQL,
    )

  let assert [table] = catalog.tables
  let assert Ok(payload_col) =
    list.find(table.columns, fn(c) { c.name == "payload" })
  payload_col.scalar_type |> should.equal(model.JsonType)
  payload_col.nullable |> should.be_false()
}

pub fn mysql_alter_change_renames_and_retypes_column_test() {
  let create =
    "CREATE TABLE `notes` (
  `id` BIGINT NOT NULL,
  `body` TEXT NOT NULL,
  PRIMARY KEY (`id`)
);
ALTER TABLE `notes` CHANGE COLUMN `body` `content` LONGTEXT NULL;"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine([#("notes.sql", create)], model.MySQL)

  let assert [table] = catalog.tables
  let column_names = list.map(table.columns, fn(c) { c.name })
  column_names |> should.equal(["id", "content"])
  let assert Ok(content_col) =
    list.find(table.columns, fn(c) { c.name == "content" })
  content_col.scalar_type |> should.equal(model.StringType)
  content_col.nullable |> should.be_true()
}

pub fn mysql_alter_modify_decimal_uses_lossless_contract_test() {
  // Verifies that the engine-aware classifier reaches the ALTER path:
  // a MODIFY changing a column to DECIMAL must produce DecimalType,
  // not the legacy FloatType collapse.
  let sql =
    "CREATE TABLE `prices` (
  `id` BIGINT NOT NULL,
  `amount` INT NOT NULL
);
ALTER TABLE `prices` MODIFY COLUMN `amount` DECIMAL(20,6) NOT NULL;"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine([#("prices.sql", sql)], model.MySQL)

  let assert [table] = catalog.tables
  let assert Ok(amount) = list.find(table.columns, fn(c) { c.name == "amount" })
  amount.scalar_type |> should.equal(model.DecimalType)
}

pub fn mysql_create_view_with_backticks_test() {
  // Backtick-quoted identifiers in CREATE VIEW must round-trip
  // through the parser (#419 acceptance criteria).
  let sql =
    "CREATE TABLE `posts` (`id` BIGINT NOT NULL, `title` VARCHAR(255) NOT NULL);
CREATE VIEW `post_titles` AS SELECT `id`, `title` FROM `posts`;"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine([#("posts.sql", sql)], model.MySQL)

  list.length(catalog.tables) |> should.equal(2)
  let assert Ok(view) =
    list.find(catalog.tables, fn(t) { t.name == "post_titles" })
  let column_names = list.map(view.columns, fn(c) { c.name })
  column_names |> should.equal(["id", "title"])
}

pub fn mysql_unsupported_ddl_fails_fast_test() {
  // Issue #419: MySQL schema files containing DDL sqlode does not
  // model must surface an actionable error rather than silently
  // dropping the statement on the floor.
  let sql =
    "CREATE TABLE `events` (`id` BIGINT NOT NULL, PRIMARY KEY (`id`));
RENAME TABLE `events` TO `events_archive`;"

  let assert Error(error) =
    schema_parser.parse_files_with_engine([#("events.sql", sql)], model.MySQL)
  let msg = schema_parser.error_to_string(error)
  string.contains(msg, "events.sql") |> should.be_true()
  string.contains(msg, "Unsupported MySQL DDL") |> should.be_true()
  string.contains(msg, "RENAME TABLE") |> should.be_true()
}

pub fn mysql_unknown_statement_for_postgresql_stays_silent_test() {
  // The fail-fast policy is scoped to MySQL — PostgreSQL keeps the
  // legacy permissive behaviour so existing schemas with adjacent
  // unrecognised DDL (e.g. plpgsql function bodies) do not break.
  let sql =
    "CREATE TABLE events (id BIGINT NOT NULL, PRIMARY KEY (id));
GRANT SELECT ON events TO some_role;"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("events.sql", sql)],
      model.PostgreSQL,
    )
  list.length(catalog.tables) |> should.equal(1)
}

pub fn mysql_create_table_strips_auto_increment_and_charset_noise_test() {
  // AUTO_INCREMENT, CHARACTER SET, COLLATE, and COMMENT all appear
  // after the column type in real MySQL DDL. They must not bleed
  // into the type text and must not produce phantom columns.
  let sql =
    "CREATE TABLE `posts` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `title` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL COMMENT 'post title',
  PRIMARY KEY (`id`)
);"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine([#("posts.sql", sql)], model.MySQL)

  let assert [table] = catalog.tables
  let column_names = list.map(table.columns, fn(c) { c.name })
  column_names |> should.equal(["id", "title"])
  let assert Ok(id_col) = list.find(table.columns, fn(c) { c.name == "id" })
  id_col.scalar_type |> should.equal(model.IntType)
  let assert Ok(title_col) =
    list.find(table.columns, fn(c) { c.name == "title" })
  title_col.scalar_type |> should.equal(model.StringType)
}
