import gleam/result
import gleam/string
import gleeunit/should
import glint
import simplifile
import sqlode/cli

const base_dir = "test_output/cli_test"

fn cleanup(subdir: String) {
  let _ = simplifile.delete(base_dir <> "/" <> subdir)
  Nil
}

fn setup(subdir: String) {
  cleanup(subdir)
  let _ = simplifile.create_directory_all(base_dir <> "/" <> subdir)
  Nil
}

fn run_init(path: String) {
  cli.app()
  |> glint.execute(["init", "--output=" <> path])
}

pub fn init_creates_config_file_test() {
  setup("config")
  let dir = base_dir <> "/config"
  let config_path = dir <> "/sqlode.yaml"

  run_init(config_path)
  |> result.is_ok
  |> should.be_true

  let assert Ok(content) = simplifile.read(config_path)
  content |> string.contains("version: \"2\"") |> should.be_true
  content |> string.contains("schema: \"db/schema.sql\"") |> should.be_true
  content |> string.contains("queries: \"db/query.sql\"") |> should.be_true
  content |> string.contains("engine: \"postgresql\"") |> should.be_true
  content |> string.contains("out: \"src/db\"") |> should.be_true
  content |> string.contains("runtime: \"raw\"") |> should.be_true

  cleanup("config")
}

pub fn init_creates_stub_schema_file_test() {
  setup("schema")
  let dir = base_dir <> "/schema"
  let config_path = dir <> "/sqlode.yaml"

  run_init(config_path)
  |> result.is_ok
  |> should.be_true

  let assert Ok(content) = simplifile.read(dir <> "/db/schema.sql")
  content |> string.contains("CREATE TABLE authors") |> should.be_true
  content |> string.contains("id BIGSERIAL PRIMARY KEY") |> should.be_true
  content |> string.contains("name TEXT NOT NULL") |> should.be_true
  content |> string.contains("bio TEXT") |> should.be_true
  content |> string.contains("created_at TIMESTAMP NOT NULL") |> should.be_true

  cleanup("schema")
}

pub fn init_creates_stub_query_file_test() {
  setup("query")
  let dir = base_dir <> "/query"
  let config_path = dir <> "/sqlode.yaml"

  run_init(config_path)
  |> result.is_ok
  |> should.be_true

  let assert Ok(content) = simplifile.read(dir <> "/db/query.sql")
  content |> string.contains("-- name: GetAuthor :one") |> should.be_true
  content |> string.contains("-- name: ListAuthors :many") |> should.be_true
  content |> string.contains("-- name: CreateAuthor :exec") |> should.be_true
  content |> string.contains("sqlode.arg(author_name)") |> should.be_true
  content |> string.contains("sqlode.narg(bio)") |> should.be_true

  cleanup("query")
}

pub fn init_does_not_overwrite_existing_stubs_test() {
  setup("no_overwrite")
  let dir = base_dir <> "/no_overwrite"
  let config_path = dir <> "/sqlode.yaml"
  let schema_path = dir <> "/db/schema.sql"
  let query_path = dir <> "/db/query.sql"

  let assert Ok(_) = simplifile.create_directory_all(dir <> "/db")
  let assert Ok(_) = simplifile.write(schema_path, "custom_schema")
  let assert Ok(_) = simplifile.write(query_path, "custom_query")

  run_init(config_path)
  |> result.is_ok
  |> should.be_true

  let assert Ok(schema) = simplifile.read(schema_path)
  schema |> should.equal("custom_schema")

  let assert Ok(query) = simplifile.read(query_path)
  query |> should.equal("custom_query")

  cleanup("no_overwrite")
}

pub fn version_command_succeeds_test() {
  cli.app()
  |> glint.execute(["version"])
  |> result.is_ok
  |> should.be_true
}

pub fn init_sqlite_engine_generates_sqlite_schema_test() {
  setup("sqlite_engine")
  let dir = base_dir <> "/sqlite_engine"
  let config_path = dir <> "/sqlode.yaml"

  cli.app()
  |> glint.execute([
    "init",
    "--output=" <> config_path,
    "--engine=sqlite",
  ])
  |> result.is_ok
  |> should.be_true

  let assert Ok(config) = simplifile.read(config_path)
  config |> string.contains("engine: \"sqlite\"") |> should.be_true

  let assert Ok(schema) = simplifile.read(dir <> "/db/schema.sql")
  schema
  |> string.contains("INTEGER PRIMARY KEY AUTOINCREMENT")
  |> should.be_true

  let assert Ok(query) = simplifile.read(dir <> "/db/query.sql")
  // SQLite uses ? placeholders
  query |> string.contains("WHERE id = ?;") |> should.be_true

  cleanup("sqlite_engine")
}

pub fn init_sqlite_native_runtime_test() {
  setup("sqlite_native")
  let dir = base_dir <> "/sqlite_native"
  let config_path = dir <> "/sqlode.yaml"

  cli.app()
  |> glint.execute([
    "init",
    "--output=" <> config_path,
    "--engine=sqlite",
    "--runtime=native",
  ])
  |> result.is_ok
  |> should.be_true

  let assert Ok(config) = simplifile.read(config_path)
  config |> string.contains("runtime: \"native\"") |> should.be_true

  cleanup("sqlite_native")
}

pub fn init_creates_missing_parent_directory_test() {
  cleanup("missing_parent")
  let dir = base_dir <> "/missing_parent"
  let nested_dir = dir <> "/config/nested"
  let config_path = nested_dir <> "/sqlode.yaml"

  run_init(config_path)
  |> result.is_ok
  |> should.be_true

  simplifile.is_file(config_path) |> should.equal(Ok(True))
  simplifile.is_file(nested_dir <> "/db/schema.sql")
  |> should.equal(Ok(True))
  simplifile.is_file(nested_dir <> "/db/query.sql") |> should.equal(Ok(True))

  cleanup("missing_parent")
}

pub fn init_mysql_engine_generates_mysql_schema_test() {
  setup("mysql_engine")
  let dir = base_dir <> "/mysql_engine"
  let config_path = dir <> "/sqlode.yaml"

  cli.app()
  |> glint.execute([
    "init",
    "--output=" <> config_path,
    "--engine=mysql",
  ])
  |> result.is_ok
  |> should.be_true

  let assert Ok(schema) = simplifile.read(dir <> "/db/schema.sql")
  schema
  |> string.contains("BIGINT AUTO_INCREMENT PRIMARY KEY")
  |> should.be_true

  cleanup("mysql_engine")
}
