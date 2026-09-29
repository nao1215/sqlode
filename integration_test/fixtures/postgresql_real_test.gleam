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
import gleam/list
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
  let _ =
    pog.query("DROP TABLE IF EXISTS posts")
    |> pog.returning(ignore())
    |> pog.execute(db)
  let _ =
    pog.query(
      "CREATE TABLE posts (id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL, tags TEXT[] NOT NULL, views INTEGER NOT NULL DEFAULT 0)",
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

// The outer side of a LEFT JOIN referenced through an alias (`s.name`)
// is nullable: the last author has no successor, so its row carries NULL.
pub fn left_join_through_alias_decodes_null_test() {
  use db <- with_db
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "First", bio: option.None),
    )
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Second", bio: option.None),
    )

  let assert Ok(rows) = pog_adapter.list_authors_with_successor(db)
  rows
  |> list.map(fn(row) { #(row.name, row.successor_name) })
  |> should.equal([
    #("First", option.Some("Second")),
    #("Second", option.None),
  ])
}

// `id = ANY($1)` binds $1 as an array: the generated parameter is a
// List(Int) and pog sends it as int8[].
pub fn any_placeholder_binds_an_array_test() {
  use db <- with_db
  let assert Ok(first) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "One", bio: option.None),
    )
  let assert Ok(_) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Two", bio: option.None),
    )
  let assert Ok(third) =
    pog_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Three", bio: option.None),
    )

  let assert Ok(rows) =
    pog_adapter.list_authors_by_ids(
      db,
      params.ListAuthorsByIdsParams(id: [first, third, 999_999]),
    )
  rows
  |> list.map(fn(row) { row.name })
  |> should.equal(["One", "Three"])
}

// `$1 = ANY(tags)` compares $1 with each element of the TEXT[] column,
// so the generated parameter is a String, not a List(String).
pub fn placeholder_any_over_array_column_binds_an_element_test() {
  use db <- with_db
  let assert Ok(first) =
    pog_adapter.create_post(
      db,
      params.CreatePostParams(title: "Gleam", tags: ["beam", "types"]),
    )
  let assert Ok(_) =
    pog_adapter.create_post(
      db,
      params.CreatePostParams(title: "SQL", tags: ["db"]),
    )
  let assert Ok(third) =
    pog_adapter.create_post(
      db,
      params.CreatePostParams(title: "Erlang", tags: ["beam"]),
    )

  let assert Ok(rows) =
    pog_adapter.list_posts_by_tag(db, params.ListPostsByTagParams(tags: "beam"))
  rows
  |> list.map(fn(row) { #(row.id, row.title) })
  |> should.equal([#(first, "Gleam"), #(third, "Erlang")])
}

// `views + $1` and `views * $1` give $1 the type of the INTEGER column.
pub fn placeholder_in_arithmetic_takes_the_column_type_test() {
  use db <- with_db
  let assert Ok(first) =
    pog_adapter.create_post(
      db,
      params.CreatePostParams(title: "Gleam", tags: []),
    )
  let assert Ok(_) =
    pog_adapter.create_post(db, params.CreatePostParams(title: "SQL", tags: []))

  let assert Ok(1) =
    pog_adapter.add_post_views(
      db,
      params.AddPostViewsParams(views: 30, id: first),
    )
  let assert Ok(rows) =
    pog_adapter.list_popular_posts(
      db,
      params.ListPopularPostsParams(views: 4),
    )
  rows
  |> list.map(fn(row) { #(row.id, row.title) })
  |> should.equal([#(first, "Gleam")])
}
