//// Exercises the generated mysql_adapter against a real MySQL
//// server. Runs only when `MYSQL_URL` is set; otherwise the main
//// function prints a skip message and exits without invoking
//// gleeunit so CI / local builds without MySQL still succeed.
////
//// The schema this test expects matches
//// `test/fixtures/mysql_real_schema.sql`. Each test drops and
//// recreates the `authors` table inside the current connection so
//// tests stay independent of each other and the initial DB state.
////
//// MYSQL_URL format: mysql://user:pass@host:port/database
////
//// Known limitation: shork's public Value type does not (yet) expose
//// a bytes constructor, so BLOB columns are encoded as NULL by the
//// generated `value_to_shork` helper. The round-trip-bytes scenario
//// from Issue #418 is currently a documented gap rather than a
//// passing test; rerun this lane with bytes support once shork (or
//// our adapter) gains a bytes encoder.

import db/models
import db/mysql_adapter
import db/params
import envoy
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import shork

pub fn main() {
  case envoy.get("MYSQL_URL") {
    Error(_) -> {
      io.println(
        "MYSQL_URL not set; skipping MySQL real-database integration tests",
      )
      Nil
    }
    Ok(_) -> gleeunit.main()
  }
}

fn parse_mysql_url(url: String) -> shork.Config {
  // Minimal mysql:// URL parser: mysql://user:pass@host:port/database
  let stripped = case string.starts_with(url, "mysql://") {
    True -> string.drop_start(url, 8)
    False -> url
  }
  let #(creds, rest) = case string.split_once(stripped, "@") {
    Ok(#(c, r)) -> #(c, r)
    Error(_) -> #("", stripped)
  }
  let #(user, password) = case string.split_once(creds, ":") {
    Ok(#(u, p)) -> #(u, p)
    Error(_) -> #(creds, "")
  }
  let #(host_part, database) = case string.split_once(rest, "/") {
    Ok(#(h, d)) -> #(h, d)
    Error(_) -> #(rest, "")
  }
  let #(host, port) = case string.split_once(host_part, ":") {
    Ok(#(h, p)) -> #(h, result.unwrap(int.parse(p), 3306))
    Error(_) -> #(host_part, 3306)
  }
  shork.default_config()
  |> shork.host(host)
  |> shork.port(port)
  |> shork.user(user)
  |> shork.password(password)
  |> shork.database(database)
}

fn connect_or_fail() -> shork.Connection {
  let assert Ok(url) = envoy.get("MYSQL_URL")
  parse_mysql_url(url) |> shork.connect
}

fn reset_authors(db: shork.Connection) -> Nil {
  // Match shork's own test fixture pattern: no `returning` decoder
  // for DDL — Query(Nil) plus a discarded result is enough.
  let _ =
    shork.query("DROP TABLE IF EXISTS authors") |> shork.execute(db)
  let _ =
    shork.query(
      "CREATE TABLE authors (id BIGINT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255) NOT NULL UNIQUE, display_name VARCHAR(255) NOT NULL, bio TEXT NULL, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)",
    )
    |> shork.execute(db)
  Nil
}

fn with_db(run: fn(shork.Connection) -> Nil) -> Nil {
  let db = connect_or_fail()
  reset_authors(db)
  run(db)
}

pub fn create_returns_positive_last_insert_id_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "alice@example.com",
        display_name: "Alice",
        bio: option.Some("a bio"),
        is_active: True,
      ),
    )
  { id > 0 } |> should.be_true()
}

pub fn get_author_round_trips_inserted_row_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "bob@example.com",
        display_name: "Bob",
        bio: option.None,
        is_active: True,
      ),
    )
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  author.id |> should.equal(id)
  author.email |> should.equal("bob@example.com")
  author.display_name |> should.equal("Bob")
  author.bio |> should.equal(option.None)
  author.is_active |> should.equal(True)
}

pub fn list_authors_returns_deterministic_order_test() {
  use db <- with_db
  let assert Ok(_) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "first@example.com",
        display_name: "First",
        bio: option.None,
        is_active: True,
      ),
    )
  let assert Ok(_) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "second@example.com",
        display_name: "Second",
        bio: option.None,
        is_active: True,
      ),
    )
  let assert Ok(authors) = mysql_adapter.list_authors(db)
  list.length(authors) |> should.equal(2)
  let names = list.map(authors, fn(a: models.ListAuthorsRow) { a.display_name })
  names |> should.equal(["First", "Second"])
}

pub fn update_bio_reports_one_changed_row_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "carol@example.com",
        display_name: "Carol",
        bio: option.None,
        is_active: True,
      ),
    )
  let assert Ok(rows) =
    mysql_adapter.update_author_bio(
      db,
      params.UpdateAuthorBioParams(id:, bio: option.Some("new bio")),
    )
  rows |> should.equal(1)

  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  author.bio |> should.equal(option.Some("new bio"))
}

pub fn delete_author_removes_row_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "dave@example.com",
        display_name: "Dave",
        bio: option.None,
        is_active: True,
      ),
    )
  let assert Ok(Nil) =
    mysql_adapter.delete_author(db, params.DeleteAuthorParams(id:))
  let assert Ok(option.None) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  Nil
}

pub fn upsert_author_updates_existing_row_test() {
  use db <- with_db
  let assert Ok(_) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "eve@example.com",
        display_name: "Eve",
        bio: option.Some("old"),
        is_active: True,
      ),
    )
  // Same email triggers ON DUPLICATE KEY UPDATE.
  let assert Ok(_) =
    mysql_adapter.upsert_author(
      db,
      params.UpsertAuthorParams(
        email: "eve@example.com",
        display_name: "Eve Updated",
        bio: option.Some("new"),
        is_active: True,
      ),
    )

  let assert Ok(authors) = mysql_adapter.list_authors(db)
  list.length(authors) |> should.equal(1)
  let assert [author] = authors
  author.display_name |> should.equal("Eve Updated")
}
