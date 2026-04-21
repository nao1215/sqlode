import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import glint
import simplifile
import sqlode/generate
import sqlode/verify
import sqlode/version

pub fn app() -> glint.Glint(Nil) {
  glint.new()
  |> glint.with_name("sqlode")
  |> glint.global_help(global_help_text())
  |> glint.pretty_help(glint.default_pretty_help())
  |> glint.add(at: ["generate"], do: generate_command())
  |> glint.add(at: ["init"], do: init_command())
  |> glint.add(at: ["verify"], do: verify_command())
  |> glint.add(at: ["version"], do: version_command())
}

fn global_help_text() -> String {
  "Generate type-safe Gleam code from SQL files using sqlc-style config.

Usage:
  sqlode generate [--config=<path>]
  sqlode verify [--config=<path>]
  sqlode init [--output=./sqlode.yaml] [--engine=postgresql|sqlite|mysql] [--runtime=raw|native]
  sqlode version

Without --config, generate/verify auto-discovers sqlode.yaml,
sqlode.yml, sqlc.yaml, sqlc.yml, or sqlc.json in the current
directory.

Run `sqlode <command> --help` for details on each command."
}

/// Candidate config filenames searched, in order, when --config is not
/// given. The first match wins; if two or more files exist the command
/// fails with a message listing them so the user picks explicitly.
const config_candidates = [
  "sqlode.yaml", "sqlode.yml", "sqlc.yaml", "sqlc.yml", "sqlc.json",
]

fn generate_command() -> glint.Command(Nil) {
  {
    use config_path <- glint.flag(
      glint.string_flag("config")
      |> glint.flag_default("")
      |> glint.flag_help(
        "Path to config file. Default: auto-discover sqlode.yaml, sqlode.yml, sqlc.yaml, sqlc.yml, or sqlc.json in the current directory.",
      ),
    )

    glint.command_help(
      "Parse SQL schema and queries, emit Gleam code.

Without --config, generate auto-discovers sqlode.yaml, sqlode.yml,
sqlc.yaml, sqlc.yml, or sqlc.json in the current directory and fails
if more than one candidate exists.

Examples:
  sqlode generate
  sqlode generate --config=./custom.yaml",
      fn() {
        glint.command(fn(_named_args, _args, flags) {
          let flag_value = config_path(flags) |> result.unwrap("")
          run_generate(flag_value)
        })
      },
    )
  }
}

fn init_command() -> glint.Command(Nil) {
  {
    use output_path <- glint.flag(
      glint.string_flag("output")
      |> glint.flag_default("./sqlode.yaml")
      |> glint.flag_help(
        "Output path for generated config (default: ./sqlode.yaml)",
      ),
    )
    use engine_flag <- glint.flag(
      glint.string_flag("engine")
      |> glint.flag_default("postgresql")
      |> glint.flag_help(
        "Target engine: postgresql | sqlite | mysql (default: postgresql)",
      ),
    )
    use runtime_flag <- glint.flag(
      glint.string_flag("runtime")
      |> glint.flag_default("raw")
      |> glint.flag_help("Generated runtime: raw | native (default: raw)"),
    )

    glint.command_help(
      "Scaffold a sqlode.yaml plus starter db/schema.sql and db/query.sql.

Examples:
  sqlode init
  sqlode init --output=./config/sqlode.yaml
  sqlode init --engine=sqlite --runtime=native
  sqlode init --engine=mysql",
      fn() {
        glint.command(fn(_named_args, _args, flags) {
          let path = output_path(flags) |> result.unwrap("./sqlode.yaml")
          let engine = engine_flag(flags) |> result.unwrap("postgresql")
          let runtime = runtime_flag(flags) |> result.unwrap("raw")
          run_init(path, engine, runtime)
        })
      },
    )
  }
}

fn verify_command() -> glint.Command(Nil) {
  {
    use config_path <- glint.flag(
      glint.string_flag("config")
      |> glint.flag_default("")
      |> glint.flag_help(
        "Path to config file. Default: auto-discover sqlode.yaml, sqlode.yml, sqlc.yaml, sqlc.yml, or sqlc.json in the current directory.",
      ),
    )

    glint.command_help(
      "Run static verification on the project without writing files.

Loads the config, parses every schema and query the generator would
use, and runs the full analyser pass. Any query-analysis error,
schema warning under strict_views, or policy violation (for example
`query_parameter_limit`) is collected into a single report.

The command exits non-zero when at least one finding is reported —
suitable for CI gates before the generation step runs.

Examples:
  sqlode verify
  sqlode verify --config=./custom.yaml",
      fn() {
        glint.command(fn(_named_args, _args, flags) {
          let flag_value = config_path(flags) |> result.unwrap("")
          run_verify(flag_value)
        })
      },
    )
  }
}

fn run_verify(flag_value: String) -> Nil {
  case resolve_config_path(flag_value) {
    Error(message) -> {
      io.println_error("Error: " <> message)
      halt(1)
    }
    Ok(config_path) -> {
      io.println("Verifying config: " <> config_path)
      case verify.run(config_path) {
        Error(err) -> {
          io.println_error("Error: " <> verify.error_to_string(err))
          halt(1)
        }
        Ok(report) -> {
          io.println(verify.report_to_string(report))
          case report.findings {
            [] -> Nil
            _ -> halt(1)
          }
        }
      }
    }
  }
}

fn version_command() -> glint.Command(Nil) {
  glint.command_help("Print the sqlode version and exit.", fn() {
    glint.command(fn(_named_args, _args, _flags) {
      io.println("sqlode v" <> version.version)
    })
  })
}

fn run_generate(flag_value: String) -> Nil {
  case resolve_config_path(flag_value) {
    Error(message) -> {
      io.println_error("Error: " <> message)
      halt(1)
    }
    Ok(config_path) -> {
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
          io.println_error("Error: " <> generate.error_to_string(error))
          halt(1)
        }
      }
    }
  }
}

fn resolve_config_path(flag_value: String) -> Result(String, String) {
  case flag_value {
    "" -> autodiscover_config()
    explicit -> Ok(explicit)
  }
}

fn autodiscover_config() -> Result(String, String) {
  let found =
    list.filter(config_candidates, fn(path) {
      case simplifile.is_file(path) {
        Ok(True) -> True
        _ -> False
      }
    })

  case found {
    [] ->
      Error(
        "No config file found. Looked for: "
        <> string.join(config_candidates, ", ")
        <> ". Create one with `sqlode init` or pass --config=<path>.",
      )
    [single] -> Ok(single)
    multiple ->
      Error(
        "Multiple config files found: "
        <> string.join(multiple, ", ")
        <> ". Pick one explicitly with --config=<path>.",
      )
  }
}

fn run_init(path: String, engine: String, runtime: String) -> Nil {
  case validate_init_flags(engine, runtime) {
    Error(msg) -> {
      io.println_error("Error: " <> msg)
      halt(1)
    }
    Ok(Nil) -> {
      let template = config_template(engine, runtime)
      case simplifile.is_file(path) {
        Ok(True) -> {
          io.println_error("Error: " <> path <> " already exists")
          halt(1)
        }
        _ -> {
          let parent_dir = filepath.directory_name(path)
          case ensure_parent_directory(parent_dir) {
            Error(msg) -> {
              io.println_error("Error: " <> msg)
              halt(1)
            }
            Ok(Nil) ->
              case simplifile.write(path, template) {
                Ok(_) -> {
                  io.println("Created " <> path)
                  create_stub_files(parent_dir, engine)
                }
                Error(err) -> {
                  io.println_error(
                    "Error: failed to write "
                    <> path
                    <> ": "
                    <> simplifile.describe_error(err),
                  )
                  halt(1)
                }
              }
          }
        }
      }
    }
  }
}

fn ensure_parent_directory(dir: String) -> Result(Nil, String) {
  case dir {
    "" | "." -> Ok(Nil)
    _ ->
      case simplifile.create_directory_all(dir) {
        Ok(Nil) -> Ok(Nil)
        Error(err) ->
          Error(
            "failed to create directory "
            <> dir
            <> ": "
            <> simplifile.describe_error(err),
          )
      }
  }
}

fn validate_init_flags(engine: String, runtime: String) -> Result(Nil, String) {
  case engine {
    "postgresql" | "sqlite" | "mysql" -> Ok(Nil)
    _ ->
      Error(
        "unsupported engine \""
        <> engine
        <> "\"; expected postgresql, sqlite, or mysql",
      )
  }
  |> result.try(fn(_) {
    case runtime {
      "raw" | "native" -> Ok(Nil)
      _ ->
        Error(
          "unsupported runtime \"" <> runtime <> "\"; expected raw or native",
        )
    }
  })
}

fn config_template(engine: String, runtime: String) -> String {
  "version: \"2\"
sql:
  - schema: \"db/schema.sql\"
    queries: \"db/query.sql\"
    engine: \"" <> engine <> "\"\n" <> "    gen:\n" <> "      gleam:\n" <> "        out: \"src/db\"\n" <> "        runtime: \"" <> runtime <> "\"\n"
}

fn create_stub_files(base_dir: String, engine: String) -> Nil {
  let schema_content = starter_schema(engine)
  let query_content = starter_query(engine)

  let db_dir = filepath.join(base_dir, "db")
  let schema_path = filepath.join(db_dir, "schema.sql")
  let query_path = filepath.join(db_dir, "query.sql")

  let _create_dir_result = simplifile.create_directory_all(db_dir)

  case simplifile.is_file(schema_path) {
    Ok(True) -> io.println("  Skipped " <> schema_path <> " (already exists)")
    _ ->
      case simplifile.write(schema_path, schema_content) {
        Ok(_) -> io.println("  Created " <> schema_path)
        Error(_) -> io.println("  Warning: failed to create " <> schema_path)
      }
  }

  case simplifile.is_file(query_path) {
    Ok(True) -> io.println("  Skipped " <> query_path <> " (already exists)")
    _ ->
      case simplifile.write(query_path, query_content) {
        Ok(_) -> io.println("  Created " <> query_path)
        Error(_) -> io.println("  Warning: failed to create " <> query_path)
      }
  }
}

fn starter_schema(engine: String) -> String {
  case engine {
    "sqlite" ->
      "CREATE TABLE authors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  bio TEXT,
  created_at TEXT NOT NULL
);
"
    "mysql" ->
      "CREATE TABLE authors (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT,
  created_at DATETIME NOT NULL
);
"
    _ ->
      "CREATE TABLE authors (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT,
  created_at TIMESTAMP NOT NULL
);
"
  }
}

fn starter_query(engine: String) -> String {
  let get_placeholder = case engine {
    "mysql" | "sqlite" -> "?"
    _ -> "$1"
  }

  "-- name: GetAuthor :one
SELECT id, name, bio
FROM authors
WHERE id = " <> get_placeholder <> ";\n" <> "\n" <> "-- name: ListAuthors :many\n" <> "SELECT id, name\n" <> "FROM authors\n" <> "ORDER BY name;\n" <> "\n" <> "-- name: CreateAuthor :exec\n" <> "INSERT INTO authors (name, bio)\n" <> "VALUES (sqlode.arg(author_name), sqlode.narg(bio));\n"
}

/// Exit the process with the given status code, flushing I/O before shutdown.
/// Uses init:stop/1 which triggers a graceful OTP shutdown instead of the
/// abrupt erlang:halt/1.
@external(erlang, "init", "stop")
fn halt(code: Int) -> Nil
