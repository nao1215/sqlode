import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import sqlode/codegen
import sqlode/config
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/schema_parser
import sqlode/writer

pub type GenerateError {
  ConfigError(config.ConfigError)
  SchemaReadError(path: String, detail: String)
  SchemaParseError(detail: String)
  QueryReadError(path: String, detail: String)
  QueryParseError(path: String, detail: String)
  NoQueriesGenerated(
    output: String,
    parsed_query_count: Int,
    schema_table_count: Int,
    query_paths: List(String),
    schema_paths: List(String),
  )
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
  let naming_ctx = naming.new()
  use files <- result.try(
    cfg.sql
    |> list.try_map(generate_sql_block(naming_ctx, _))
    |> result.map(list.flatten),
  )

  writer.write_all(files)
  |> result.map_error(WriteError)
}

fn generate_sql_block(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
) -> Result(List(writer.GeneratedFile), GenerateError) {
  use raw_catalog <- result.try(load_catalog(block.schema))
  let catalog =
    apply_type_overrides(raw_catalog, block.overrides.type_overrides)
  use queries <- result.try(load_queries(naming_ctx, block))
  let analyzed =
    query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, queries)
    |> apply_column_renames(block.overrides.column_renames)

  let model.SqlBlock(gleam:, ..) = block
  let model.GleamOutput(out:, ..) = gleam

  case analyzed {
    [] ->
      Error(NoQueriesGenerated(
        output: out,
        parsed_query_count: list.length(queries),
        schema_table_count: list.length(catalog.tables),
        query_paths: block.queries,
        schema_paths: block.schema,
      ))
    _ -> {
      let has_row_types =
        list.any(analyzed, fn(query) {
          case query.base.command {
            model.One | model.Many -> !list.is_empty(query.result_columns)
            _ -> False
          }
        })

      let base_files = [
        writer.GeneratedFile(
          directory: out,
          path: "params.gleam",
          content: codegen.render_params_module(naming_ctx, analyzed),
        ),
        writer.GeneratedFile(
          directory: out,
          path: "queries.gleam",
          content: codegen.render_queries_module(block, analyzed),
        ),
      ]

      let files = case has_row_types {
        True ->
          list.append(base_files, [
            writer.GeneratedFile(
              directory: out,
              path: "models.gleam",
              content: codegen.render_models_module(naming_ctx, analyzed),
            ),
          ])
        False -> base_files
      }

      let files = case gleam.runtime {
        model.Raw -> files
        _ ->
          list.append(files, [
            writer.GeneratedFile(
              directory: out,
              path: adapter_filename(block.engine),
              content: codegen.render_adapter_module(
                naming_ctx,
                block,
                analyzed,
              ),
            ),
          ])
      }

      Ok(files)
    }
  }
}

fn load_catalog(paths: List(String)) -> Result(model.Catalog, GenerateError) {
  use entries <- result.try(
    paths
    |> list.try_map(fn(path) {
      simplifile.read(path)
      |> result.map(fn(content) { #(path, content) })
      |> result.map_error(fn(error) {
        SchemaReadError(
          path:,
          detail: "Failed to read schema file: "
            <> simplifile.describe_error(error),
        )
      })
    }),
  )

  schema_parser.parse_files(entries)
  |> result.map_error(fn(error) {
    SchemaParseError(detail: schema_parser.error_to_string(error))
  })
}

fn load_queries(
  naming_ctx: naming.NamingContext,
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

    query_parser.parse_file(path, engine, naming_ctx, content)
    |> result.map_error(fn(error) {
      QueryParseError(path:, detail: query_parser.error_to_string(error))
    })
  })
  |> result.map(list.flatten)
}

fn apply_type_overrides(
  catalog: model.Catalog,
  overrides: List(model.TypeOverride),
) -> model.Catalog {
  case overrides {
    [] -> catalog
    _ -> {
      let tables =
        list.map(catalog.tables, fn(table) {
          let columns =
            list.map(table.columns, fn(col) {
              case find_type_override(col.scalar_type, overrides) {
                Ok(gleam_type) ->
                  model.Column(
                    ..col,
                    scalar_type: gleam_type_to_scalar(gleam_type),
                  )
                Error(_) -> col
              }
            })
          model.Table(..table, columns:)
        })
      model.Catalog(..catalog, tables:)
    }
  }
}

fn find_type_override(
  scalar_type: model.ScalarType,
  overrides: List(model.TypeOverride),
) -> Result(String, Nil) {
  let type_name = scalar_type_name(scalar_type)

  list.find_map(overrides, fn(ovr) {
    case string.lowercase(ovr.db_type) == type_name {
      True -> Ok(ovr.gleam_type)
      False -> Error(Nil)
    }
  })
}

fn scalar_type_name(scalar_type: model.ScalarType) -> String {
  case scalar_type {
    model.IntType -> "int"
    model.FloatType -> "float"
    model.BoolType -> "bool"
    model.StringType -> "string"
    model.BytesType -> "bytes"
    model.DateTimeType -> "datetime"
    model.DateType -> "date"
    model.TimeType -> "time"
    model.UuidType -> "uuid"
    model.JsonType -> "json"
    model.EnumType(name) -> name
  }
}

fn gleam_type_to_scalar(gleam_type: String) -> model.ScalarType {
  case string.lowercase(gleam_type) {
    "int" -> model.IntType
    "float" -> model.FloatType
    "bool" -> model.BoolType
    "bitarray" -> model.BytesType
    _ -> model.StringType
  }
}

fn apply_column_renames(
  queries: List(model.AnalyzedQuery),
  renames: List(model.ColumnRename),
) -> List(model.AnalyzedQuery) {
  case renames {
    [] -> queries
    _ ->
      list.map(queries, fn(query) {
        let sql_lowered = string.lowercase(query.base.sql)
        let applicable_renames =
          list.filter(renames, fn(r) {
            string.contains(sql_lowered, string.lowercase(r.table))
          })
        let result_columns =
          list.map(query.result_columns, fn(col) {
            case find_column_rename(col.name, applicable_renames) {
              Ok(new_name) -> model.ResultColumn(..col, name: new_name)
              Error(_) -> col
            }
          })
        model.AnalyzedQuery(..query, result_columns:)
      })
  }
}

fn find_column_rename(
  column_name: String,
  renames: List(model.ColumnRename),
) -> Result(String, Nil) {
  list.find_map(renames, fn(r) {
    case string.lowercase(r.column) == string.lowercase(column_name) {
      True -> Ok(r.rename_to)
      False -> Error(Nil)
    }
  })
}

fn adapter_filename(engine: model.Engine) -> String {
  case engine {
    model.PostgreSQL -> "pog_adapter.gleam"
    model.SQLite -> "sqlight_adapter.gleam"
    model.MySQL -> "mysql_adapter.gleam"
  }
}

pub fn error_to_string(error: GenerateError) -> String {
  case error {
    ConfigError(inner) -> config.error_to_string(inner)
    SchemaReadError(path:, detail:) -> path <> ": " <> detail
    SchemaParseError(detail:) -> detail
    QueryReadError(path:, detail:) -> path <> ": " <> detail
    QueryParseError(detail:, ..) -> detail
    NoQueriesGenerated(
      output:,
      parsed_query_count:,
      schema_table_count:,
      query_paths:,
      schema_paths:,
    ) ->
      "No queries were generated for output directory: "
      <> output
      <> "\n  Parsed queries: "
      <> int.to_string(parsed_query_count)
      <> " (from "
      <> string.join(query_paths, ", ")
      <> ")"
      <> "\n  Schema tables: "
      <> int.to_string(schema_table_count)
      <> " (from "
      <> string.join(schema_paths, ", ")
      <> ")"
      <> case parsed_query_count {
        0 ->
          "\n  Hint: No queries were found. Ensure your query files contain annotations like '-- name: QueryName :one'"
        _ ->
          case schema_table_count {
            0 ->
              "\n  Hint: No tables found in schema. Ensure your schema files contain CREATE TABLE statements"
            _ ->
              "\n  Hint: Queries were parsed but none produced output. Check that your schema defines the tables referenced in your queries"
          }
      }
    WriteError(inner) -> writer.error_to_string(inner)
  }
}
