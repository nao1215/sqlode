//// Exercises the generated pog adapter against a real PostgreSQL
//// server. Runs only when `DATABASE_URL` is set; otherwise the main
//// function prints a skip message and exits without invoking gleeunit
//// so CI / local builds without Postgres still succeed.
////
//// The schema this test expects matches
//// `test/fixtures/postgresql_schema.sql`. Each test drops and
//// recreates the `authors` table inside the current connection so
//// tests stay independent of each other and the initial DB state.

import db/params
import db/pog_adapter
import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import pog

pub fn main() {
  case envoy.get("DATABASE_URL") {
    Error(_) -> {
      io.println(
        "DATABASE_URL not set; skipping PostgreSQL real-database integration tests",
      )
      Nil
    }
    Ok(_) -> gleeunit.main()
  }
}

fn connect_or_fail() -> pog.Connection {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let pool_name = process.new_name("sqlode_pg_integration_pool")
  let assert Ok(config) = pog.url_config(pool_name, url)
  let assert Ok(actor.Started(_pid, conn)) = pog.start(config)
  conn
}

fn ignore() -> decode.Decoder(Nil) {
  decode.success(Nil)
}

fn reset_authors(db: pog.Connection) -> Nil {
  let _ =
    pog.query("DROP TABLE IF EXISTS authors")
    |> pog.returning(ignore())
    |> pog.execute(db)
  let _ =
    pog.query(
      "CREATE TABLE authors (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, bio TEXT)",
    )
    |> pog.returning(ignore())
    |> pog.execute(db)
  Nil
}

fn with_db(run: fn(pog.Connection) -> Nil) -> Nil {
  let db = connect_or_fail()
  reset_authors(db)
  run(db)
}

pub fn create_and_get_author_test() {
  use db <- with_db
  let assert Ok(author_id) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("A bio")),
    )
  author_id |> should.not_equal(0)

  let assert Ok(option.Some(author)) =
    pog_adapter.get_author(db, params.GetAuthorParams(id: author_id))
  author.id |> should.equal(author_id)
  author.name |> should.equal("Alice")
  author.bio |> should.equal(option.Some("A bio"))
}

pub fn list_authors_orders_by_name_test() {
  use db <- with_db
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: option.None),
    )
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("bio")),
    )

  let assert Ok(authors) = pog_adapter.list_authors(db)
  case authors {
    [first, second] -> {
      first.name |> should.equal("Alice")
      second.name |> should.equal("Bob")
    }
    _ -> should.fail()
  }
}

pub fn create_author_with_null_bio_test() {
  use db <- with_db
  let assert Ok(id) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "NoBio", bio: option.None),
    )

  let assert Ok(option.Some(author)) =
    pog_adapter.get_author(db, params.GetAuthorParams(id: id))
  author.bio |> should.equal(option.None)
}

pub fn get_nonexistent_author_returns_none_test() {
  use db <- with_db
  let assert Ok(option.None) =
    pog_adapter.get_author(db, params.GetAuthorParams(id: 999_999))
  Nil
}

pub fn delete_author_test() {
  use db <- with_db
  let assert Ok(id) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Charlie", bio: option.None),
    )
  let assert Ok(Nil) =
    pog_adapter.delete_author(db, params.DeleteAuthorParams(id: id))
  let assert Ok(option.None) =
    pog_adapter.get_author(db, params.GetAuthorParams(id: id))
  Nil
}

pub fn count_authors_returns_row_count_test() {
  use db <- with_db
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "A", bio: option.None),
    )
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "B", bio: option.None),
    )
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "C", bio: option.None),
    )

  let assert Ok(option.Some(row)) = pog_adapter.count_authors(db)
  row.total |> should.equal(3)
}
