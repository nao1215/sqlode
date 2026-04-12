import gleam/int
import gleam/io
import gleam/list
import gleam/result
import glint
import simplifile
import sqlode/generate

pub fn app() -> glint.Glint(Nil) {
  glint.new()
  |> glint.with_name("sqlode")
  |> glint.global_help(
    "Generate Gleam code from SQL files using sqlc-style config",
  )
  |> glint.pretty_help(glint.default_pretty_help())
  |> glint.add(at: ["generate"], do: generate_command())
  |> glint.add(at: ["init"], do: init_command())
}

fn generate_command() -> glint.Command(Nil) {
  {
    use config_path <- glint.flag(
      glint.string_flag("config")
      |> glint.flag_default("./sqlode.yaml")
      |> glint.flag_help("Path to config file"),
    )

    glint.command_help("Generate Gleam files from SQL", fn() {
      glint.command(fn(_named_args, _args, flags) {
        let config_path = config_path(flags) |> result.unwrap("./sqlode.yaml")
        run_generate(config_path)
      })
    })
  }
}

fn init_command() -> glint.Command(Nil) {
  {
    use output_path <- glint.flag(
      glint.string_flag("output")
      |> glint.flag_default("./sqlode.yaml")
      |> glint.flag_help("Output path for config file"),
    )

    glint.command_help("Create a sqlode.yaml config file", fn() {
      glint.command(fn(_named_args, _args, flags) {
        let path = output_path(flags) |> result.unwrap("./sqlode.yaml")
        run_init(path)
      })
    })
  }
}

fn run_generate(config_path: String) -> Nil {
  io.println("sqlode v0.1.0")
  io.println("Loading config from: " <> config_path)

  case generate.run(config_path) {
    Ok(written) -> {
      io.println("")
      io.println(
        "Successfully generated "
        <> int.to_string(list.length(written))
        <> " files",
      )
      list.each(written, fn(path) { io.println("  Generated: " <> path) })
    }
    Error(error) -> {
      io.println("Error: " <> generate.error_to_string(error))
      halt(1)
    }
  }
}

fn run_init(path: String) -> Nil {
  let template =
    "version: \"2\"\n"
    <> "sql:\n"
    <> "  - schema: \"db/schema.sql\"\n"
    <> "    queries: \"db/query.sql\"\n"
    <> "    engine: \"postgresql\"\n"
    <> "    gen:\n"
    <> "      gleam:\n"
    <> "        package: \"db\"\n"
    <> "        out: \"src/db\"\n"
    <> "        runtime: \"raw\"\n"

  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println("Error: " <> path <> " already exists")
      halt(1)
    }
    _ -> {
      case simplifile.write(path, template) {
        Ok(_) -> {
          io.println("Created " <> path)
          create_stub_files()
        }
        Error(_) -> {
          io.println("Error: failed to write " <> path)
          halt(1)
        }
      }
    }
  }
}

fn create_stub_files() -> Nil {
  let schema_content =
    "CREATE TABLE authors (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL,\n"
    <> "  bio TEXT\n"
    <> ");\n"

  let query_content =
    "-- name: GetAuthor :one\n"
    <> "SELECT id, name, bio\n"
    <> "FROM authors\n"
    <> "WHERE id = $1;\n"
    <> "\n"
    <> "-- name: ListAuthors :many\n"
    <> "SELECT id, name\n"
    <> "FROM authors\n"
    <> "ORDER BY name;\n"

  let _ = simplifile.create_directory_all("db")

  case simplifile.is_file("db/schema.sql") {
    Ok(True) -> io.println("  Skipped db/schema.sql (already exists)")
    _ ->
      case simplifile.write("db/schema.sql", schema_content) {
        Ok(_) -> io.println("  Created db/schema.sql")
        Error(_) -> io.println("  Warning: failed to create db/schema.sql")
      }
  }

  case simplifile.is_file("db/query.sql") {
    Ok(True) -> io.println("  Skipped db/query.sql (already exists)")
    _ ->
      case simplifile.write("db/query.sql", query_content) {
        Ok(_) -> io.println("  Created db/query.sql")
        Error(_) -> io.println("  Warning: failed to create db/query.sql")
      }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
