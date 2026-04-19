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
  let _ = shork.query("DROP TABLE IF EXISTS authors") |> shork.execute(db)
  let _ =
    shork.query(
      "CREATE TABLE authors (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        email VARCHAR(255) NOT NULL UNIQUE,
        display_name VARCHAR(255) NOT NULL,
        bio TEXT NULL,
        is_active BOOLEAN NOT NULL DEFAULT TRUE,
        avatar BLOB NULL,
        balance DECIMAL(20,6) NOT NULL DEFAULT '0.000000',
        status ENUM('draft','published','archived') NOT NULL DEFAULT 'draft',
        tags SET('red','green','blue') NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )",
    )
    |> shork.execute(db)
  Nil
}

fn with_db(run: fn(shork.Connection) -> Nil) -> Nil {
  let db = connect_or_fail()
  reset_authors(db)
  run(db)
}

fn default_create_params(
  email: String,
  display_name: String,
) -> params.CreateAuthorParams {
  params.CreateAuthorParams(
    email:,
    display_name:,
    bio: option.None,
    is_active: True,
    avatar: option.None,
    balance: "0.000000",
    status: models.Draft,
    tags: option.None,
  )
}

pub fn create_returns_positive_last_insert_id_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      default_create_params("alice@example.com", "Alice"),
    )
  { id > 0 } |> should.be_true()
}

pub fn get_author_round_trips_inserted_row_test() {
  use db <- with_db
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      default_create_params("bob@example.com", "Bob"),
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
      default_create_params("first@example.com", "First"),
    )
  let assert Ok(_) =
    mysql_adapter.create_author(
      db,
      default_create_params("second@example.com", "Second"),
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
      default_create_params("carol@example.com", "Carol"),
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
      default_create_params("dave@example.com", "Dave"),
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
      default_create_params("eve@example.com", "Eve"),
    )
  let updated = params.UpsertAuthorParams(
    email: "eve@example.com",
    display_name: "Eve Updated",
    bio: option.Some("new"),
    is_active: True,
    avatar: option.None,
    balance: "0.000000",
    status: models.Draft,
    tags: option.None,
  )
  let assert Ok(_) = mysql_adapter.upsert_author(db, updated)

  let assert Ok(authors) = mysql_adapter.list_authors(db)
  list.length(authors) |> should.equal(1)
  let assert [author] = authors
  author.display_name |> should.equal("Eve Updated")
}

// Issue #418 / #422 round-trip coverage for the previously-documented
// gaps: bytes (BLOB), decimal (DECIMAL(20,6) lossless contract),
// ENUM, and MySQL SET.

pub fn bytes_avatar_round_trips_byte_for_byte_test() {
  use db <- with_db
  let avatar = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF>>
  let create =
    params.CreateAuthorParams(
      email: "frank@example.com",
      display_name: "Frank",
      bio: option.None,
      is_active: True,
      avatar: option.Some(avatar),
      balance: "0.000000",
      status: models.Draft,
      tags: option.None,
    )
  let assert Ok(id) = mysql_adapter.create_author(db, create)
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  author.avatar |> should.equal(option.Some(avatar))
}

pub fn decimal_balance_round_trips_lossless_test() {
  use db <- with_db
  let balance = "12345678901234.567890"
  let create =
    params.CreateAuthorParams(
      email: "grace@example.com",
      display_name: "Grace",
      bio: option.None,
      is_active: True,
      avatar: option.None,
      balance: balance,
      status: models.Draft,
      tags: option.None,
    )
  let assert Ok(id) = mysql_adapter.create_author(db, create)
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  // MySQL stores DECIMAL exactly to the schema's precision/scale, so
  // the value we wrote and the value we read should be identical
  // strings — that is the whole point of `DecimalType` over Float.
  author.balance |> should.equal(balance)
}

pub fn enum_status_round_trips_through_helpers_test() {
  use db <- with_db
  let create =
    params.CreateAuthorParams(
      email: "harry@example.com",
      display_name: "Harry",
      bio: option.None,
      is_active: True,
      avatar: option.None,
      balance: "0.000000",
      status: models.Published,
      tags: option.None,
    )
  let assert Ok(id) = mysql_adapter.create_author(db, create)
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  author.status |> should.equal(models.Published)
}

pub fn set_tags_round_trips_through_helpers_test() {
  use db <- with_db
  let tags = [models.Red, models.Green]
  let create =
    params.CreateAuthorParams(
      email: "ivy@example.com",
      display_name: "Ivy",
      bio: option.None,
      is_active: True,
      avatar: option.None,
      balance: "0.000000",
      status: models.Draft,
      tags: option.Some(tags),
    )
  let assert Ok(id) = mysql_adapter.create_author(db, create)
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  author.tags |> should.equal(option.Some(tags))
}
