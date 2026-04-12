import gleam/list
import gleam/result
import simplifile
import sqlode/codegen
import sqlode/config
import sqlode/model
import sqlode/query_parser
import sqlode/writer

pub type GenerateError {
  ConfigError(config.ConfigError)
  SchemaReadError(path: String, detail: String)
  QueryReadError(path: String, detail: String)
  QueryParseError(path: String, detail: String)
  NoQueriesGenerated(output: String)
  WriteError(writer.WriteError)
}

pub fn run(config_path: String) -> Result(List(String), GenerateError) {
  use cfg <- result.try(
    config.load(config_path)
    |> result.map_error(ConfigError),
  )

  generate_config(cfg)
}

pub fn generate_config(cfg: model.Config) -> Result(List(String), GenerateError) {
  use files <- result.try(
    cfg.sql
    |> list.try_map(generate_sql_block)
    |> result.map(list.flatten),
  )

  writer.write_all(files)
  |> result.map_error(WriteError)
}

fn generate_sql_block(
  block: model.SqlBlock,
) -> Result(List(writer.GeneratedFile), GenerateError) {
  use _ <- result.try(validate_schema_files(block.schema))
  use queries <- result.try(load_queries(block))

  let model.SqlBlock(gleam:, ..) = block
  let model.GleamOutput(out:, ..) = gleam

  case queries {
    [] -> Error(NoQueriesGenerated(output: out))
    _ ->
      Ok([
        writer.GeneratedFile(
          directory: out,
          path: "queries.gleam",
          content: codegen.render_queries_module(block, queries),
        ),
      ])
  }
}

fn validate_schema_files(paths: List(String)) -> Result(Nil, GenerateError) {
  paths
  |> list.try_fold(Nil, fn(_, path) {
    simplifile.read(path)
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) {
      SchemaReadError(
        path:,
        detail: "Failed to read schema file: "
          <> simplifile.describe_error(error),
      )
    })
  })
}

fn load_queries(
  block: model.SqlBlock,
) -> Result(List(model.ParsedQuery), GenerateError) {
  let model.SqlBlock(engine:, queries:, ..) = block

  queries
  |> list.try_map(fn(path) {
    use content <- result.try(
      simplifile.read(path)
      |> result.map_error(fn(error) {
        QueryReadError(
          path:,
          detail: "Failed to read query file: "
            <> simplifile.describe_error(error),
        )
      }),
    )

    query_parser.parse_file(path, engine, content)
    |> result.map_error(fn(error) {
      QueryParseError(path:, detail: query_parser.error_to_string(error))
    })
  })
  |> result.map(list.flatten)
}

pub fn error_to_string(error: GenerateError) -> String {
  case error {
    ConfigError(inner) -> config.error_to_string(inner)
    SchemaReadError(path:, detail:) -> path <> ": " <> detail
    QueryReadError(path:, detail:) -> path <> ": " <> detail
    QueryParseError(detail:, ..) -> detail
    NoQueriesGenerated(output:) ->
      "No queries were generated for output directory: " <> output
    WriteError(inner) -> writer.error_to_string(inner)
  }
}
