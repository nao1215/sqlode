import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile
import sqlode/codegen
import sqlode/codegen/common
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
  QueryAnalysisError(detail: String)
  NoQueriesGenerated(
    output: String,
    parsed_query_count: Int,
    schema_table_count: Int,
    query_paths: List(String),
    schema_paths: List(String),
  )
  UnsupportedAnnotation(query_name: String, command: String, detail: String)
  WriteError(writer.WriteError)
}

pub fn run(config_path: String) -> Result(List(String), GenerateError) {
  use cfg <- result.try(
    config.load(config_path)
    |> result.map_error(ConfigError),
  )

  let config_dir = filepath.directory_name(config_path)
  let resolved = resolve_config_paths(cfg, config_dir)
  generate_config(resolved)
}

fn resolve_config_paths(cfg: model.Config, base_dir: String) -> model.Config {
  let sql =
    list.map(cfg.sql, fn(block) {
      let schema = list.map(block.schema, resolve_path(base_dir, _))
      let queries = list.map(block.queries, resolve_path(base_dir, _))
      let gleam =
        model.GleamOutput(
          ..block.gleam,
          out: resolve_path(base_dir, block.gleam.out),
        )
      model.SqlBlock(..block, schema:, queries:, gleam:)
    })
  model.Config(..cfg, sql:)
}

fn resolve_path(base_dir: String, path: String) -> String {
  case filepath.is_absolute(path) {
    True -> path
    False ->
      case filepath.expand(filepath.join(base_dir, path)) {
        Ok(expanded) -> expanded
        Error(_) -> filepath.join(base_dir, path)
      }
  }
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
  use analyzed <- result.try(
    query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, queries)
    |> result.map_error(fn(error) {
      QueryAnalysisError(detail: query_analyzer.analysis_error_to_string(error))
    }),
  )
  use Nil <- result.try(validate_unsupported_annotations(analyzed))
  let analyzed = apply_column_renames(analyzed, block.overrides.column_renames)

  let model.SqlBlock(gleam:, ..) = block
  let model.GleamOutput(out:, ..) = gleam

  let table_matches =
    compute_table_matches(
      naming_ctx,
      catalog,
      analyzed,
      gleam.emit_exact_table_names,
    )

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
          model.is_result_command(query.base.command)
          && !list.is_empty(query.result_columns)
        })

      let has_models = has_row_types || !list.is_empty(catalog.tables)

      let base_files = [
        writer.GeneratedFile(
          directory: out,
          path: "params.gleam",
          content: codegen.render_params_module(
            naming_ctx,
            analyzed,
            gleam.type_mapping,
            common.out_to_module_path(out),
          ),
        ),
        writer.GeneratedFile(
          directory: out,
          path: "queries.gleam",
          content: codegen.render_queries_module(naming_ctx, block, analyzed),
        ),
      ]

      let files = case has_models {
        True ->
          list.append(base_files, [
            writer.GeneratedFile(
              directory: out,
              path: "models.gleam",
              content: codegen.render_models_module(
                naming_ctx,
                catalog,
                analyzed,
                table_matches,
                gleam.type_mapping,
                gleam.emit_exact_table_names,
              ),
            ),
          ])
        False -> base_files
      }

      case gleam.runtime {
        model.Raw -> Ok(files)
        model.Native -> {
          use Nil <- result.try(validate_native_annotations(analyzed))
          Ok(
            list.append(files, [
              writer.GeneratedFile(
                directory: out,
                path: adapter_filename(block.engine),
                content: codegen.render_adapter_module(
                  naming_ctx,
                  block,
                  analyzed,
                  table_matches,
                ),
              ),
            ]),
          )
        }
      }
    }
  }
}

fn expand_sql_paths(
  paths: List(String),
  error_fn: fn(String, String) -> GenerateError,
) -> Result(List(String), GenerateError) {
  paths
  |> list.try_map(fn(path) {
    case simplifile.is_directory(path) {
      Ok(True) ->
        case simplifile.get_files(in: path) {
          Ok(files) -> {
            let sql_files =
              files
              |> list.filter(fn(f) { string.ends_with(f, ".sql") })
              |> list.sort(string.compare)
            case sql_files {
              [] -> Error(error_fn(path, "Directory contains no .sql files"))
              _ -> Ok(sql_files)
            }
          }
          Error(error) ->
            Error(error_fn(
              path,
              "Failed to read directory: " <> simplifile.describe_error(error),
            ))
        }
      Ok(False) -> Ok([path])
      Error(error) ->
        Error(error_fn(
          path,
          "Failed to access path: " <> simplifile.describe_error(error),
        ))
    }
  })
  |> result.map(list.flatten)
}

fn load_catalog(paths: List(String)) -> Result(model.Catalog, GenerateError) {
  use expanded <- result.try(
    expand_sql_paths(paths, fn(path, detail) { SchemaReadError(path:, detail:) }),
  )
  use entries <- result.try(
    expanded
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

  use expanded <- result.try(
    expand_sql_paths(queries, fn(path, detail) {
      QueryReadError(path:, detail:)
    }),
  )

  expanded
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
              case find_column_override(table.name, col.name, overrides) {
                Ok(gleam_type) ->
                  model.Column(
                    ..col,
                    scalar_type: gleam_type_to_scalar(
                      gleam_type,
                      col.scalar_type,
                    ),
                  )
                Error(_) ->
                  case
                    find_db_type_override(
                      col.scalar_type,
                      col.nullable,
                      overrides,
                    )
                  {
                    Ok(gleam_type) ->
                      model.Column(
                        ..col,
                        scalar_type: gleam_type_to_scalar(
                          gleam_type,
                          col.scalar_type,
                        ),
                      )
                    Error(_) -> col
                  }
              }
            })
          model.Table(..table, columns:)
        })
      model.Catalog(..catalog, tables:)
    }
  }
}

fn find_column_override(
  table_name: String,
  column_name: String,
  overrides: List(model.TypeOverride),
) -> Result(String, Nil) {
  list.find_map(overrides, fn(ovr) {
    case ovr {
      model.ColumnOverride(table:, column:, gleam_type:) ->
        case
          string.lowercase(table) == string.lowercase(table_name)
          && string.lowercase(column) == string.lowercase(column_name)
        {
          True -> Ok(gleam_type)
          False -> Error(Nil)
        }
      model.DbTypeOverride(..) -> Error(Nil)
    }
  })
}

fn find_db_type_override(
  scalar_type: model.ScalarType,
  is_nullable: Bool,
  overrides: List(model.TypeOverride),
) -> Result(String, Nil) {
  let type_name = model.scalar_type_to_db_name(scalar_type)

  list.find_map(overrides, fn(ovr) {
    case ovr {
      model.DbTypeOverride(db_type:, gleam_type:, nullable:) ->
        case string.lowercase(db_type) == type_name {
          True ->
            case nullable {
              option.None -> Ok(gleam_type)
              option.Some(n) ->
                case n == is_nullable {
                  True -> Ok(gleam_type)
                  False -> Error(Nil)
                }
            }
          False -> Error(Nil)
        }
      model.ColumnOverride(..) -> Error(Nil)
    }
  })
}

fn gleam_type_to_scalar(
  gleam_type: String,
  underlying: model.ScalarType,
) -> model.ScalarType {
  case string.lowercase(gleam_type) {
    "int" -> model.IntType
    "float" -> model.FloatType
    "bool" -> model.BoolType
    "string" -> model.StringType
    "bitarray" -> model.BytesType
    _ -> {
      let underlying_name =
        model.scalar_type_to_gleam_type(underlying, model.StringMapping)
      io.println_error(
        "Warning: custom gleam_type \""
        <> gleam_type
        <> "\" will use the encoder/decoder for the underlying \""
        <> underlying_name
        <> "\" type. Ensure \""
        <> gleam_type
        <> "\" is defined as a transparent type alias (e.g., pub type "
        <> gleam_type
        <> " = "
        <> underlying_name
        <> "). Opaque types are not supported.",
      )
      model.CustomType(name: gleam_type, underlying:)
    }
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
        let result_columns =
          list.map(query.result_columns, fn(col) {
            case col {
              model.ResultColumn(name:, source_table:, ..) ->
                case find_column_rename(name, source_table, renames) {
                  Ok(new_name) -> model.ResultColumn(..col, name: new_name)
                  Error(_) -> col
                }
              model.EmbeddedColumn(..) -> col
            }
          })
        model.AnalyzedQuery(..query, result_columns:)
      })
  }
}

fn find_column_rename(
  column_name: String,
  source_table: option.Option(String),
  renames: List(model.ColumnRename),
) -> Result(String, Nil) {
  list.find_map(renames, fn(r) {
    let column_matches =
      string.lowercase(r.column) == string.lowercase(column_name)
    let table_matches = case source_table {
      option.Some(table) -> string.lowercase(r.table) == string.lowercase(table)
      option.None -> False
    }
    case column_matches && table_matches {
      True -> Ok(r.rename_to)
      False -> Error(Nil)
    }
  })
}

fn validate_unsupported_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, GenerateError) {
  let unsupported = fn(command: model.QueryCommand) -> Bool {
    case command {
      model.BatchOne | model.BatchMany | model.BatchExec | model.CopyFrom ->
        True
      _ -> False
    }
  }
  case list.find(queries, fn(q) { unsupported(q.base.command) }) {
    Ok(q) -> {
      let #(command, alternative) = case q.base.command {
        model.BatchOne -> #(":batchone", ":one")
        model.BatchMany -> #(":batchmany", ":many")
        model.BatchExec -> #(":batchexec", ":exec")
        model.CopyFrom -> #(":copyfrom", ":exec")
        _ -> #("", ":exec")
      }
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: command,
        detail: command
          <> " is not yet supported. Use "
          <> alternative
          <> " instead",
      ))
    }
    Error(_) -> Ok(Nil)
  }
}

fn validate_native_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, GenerateError) {
  case list.find(queries, fn(q) { q.base.command == model.ExecResult }) {
    Ok(q) ->
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: ":execresult",
        detail: ":execresult is not supported with native runtime. Use :exec, :execrows, or :execlastid instead",
      ))
    Error(_) -> Ok(Nil)
  }
}

fn adapter_filename(engine: model.Engine) -> String {
  case engine {
    model.PostgreSQL -> "pog_adapter.gleam"
    model.SQLite -> "sqlight_adapter.gleam"
    model.MySQL -> "mysql_adapter.gleam"
  }
}

/// Compute a mapping from query function_name to PascalCase table type name
/// for queries whose result columns exactly match a table in the catalog.
fn compute_table_matches(
  naming_ctx: naming.NamingContext,
  catalog: model.Catalog,
  queries: List(model.AnalyzedQuery),
  emit_exact_table_names: Bool,
) -> Dict(String, String) {
  queries
  |> list.filter_map(fn(query) {
    try_match_query_to_table(naming_ctx, catalog, query, emit_exact_table_names)
  })
  |> dict.from_list
}

fn try_match_query_to_table(
  naming_ctx: naming.NamingContext,
  catalog: model.Catalog,
  query: model.AnalyzedQuery,
  emit_exact_table_names: Bool,
) -> Result(#(String, String), Nil) {
  // Only result-returning commands can match a table
  use <- guard_result(model.is_result_command(query.base.command))

  // Queries with embedded columns never match a single table
  let has_embed =
    list.any(query.result_columns, fn(col) {
      case col {
        model.EmbeddedColumn(..) -> True
        _ -> False
      }
    })
  use <- guard_result(!has_embed)

  // Extract the source table from the first result column
  use table_name <- result.try(case query.result_columns {
    [model.ResultColumn(source_table: option.Some(name), ..), ..] -> Ok(name)
    _ -> Error(Nil)
  })

  // All result columns must come from the same table
  let all_same_table =
    list.all(query.result_columns, fn(col) {
      case col {
        model.ResultColumn(source_table: src, ..) ->
          src == option.Some(table_name)
        model.EmbeddedColumn(..) -> False
      }
    })
  use <- guard_result(all_same_table)

  // The table must exist and columns must match exactly
  use table <- result.try(find_table(catalog, table_name))
  use <- guard_result(columns_match(query.result_columns, table.columns))

  Ok(#(
    query.base.function_name,
    naming.table_type_name(naming_ctx, table_name, emit_exact_table_names),
  ))
}

fn guard_result(condition: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case condition {
    True -> next()
    False -> Error(Nil)
  }
}

fn find_table(
  catalog: model.Catalog,
  table_name: String,
) -> Result(model.Table, Nil) {
  list.find(catalog.tables, fn(t) {
    string.lowercase(t.name) == string.lowercase(table_name)
  })
}

fn columns_match(
  result_columns: List(model.ResultColumn),
  table_columns: List(model.Column),
) -> Bool {
  case list.length(result_columns) == list.length(table_columns) {
    False -> False
    True ->
      list.zip(result_columns, table_columns)
      |> list.all(fn(pair) {
        let #(rc, tc) = pair
        case rc {
          model.ResultColumn(name:, scalar_type:, nullable:, ..) ->
            string.lowercase(name) == string.lowercase(tc.name)
            && scalar_type == tc.scalar_type
            && nullable == tc.nullable
          model.EmbeddedColumn(..) -> False
        }
      })
  }
}

pub fn error_to_string(error: GenerateError) -> String {
  case error {
    ConfigError(inner) -> config.error_to_string(inner)
    SchemaReadError(path:, detail:) -> path <> ": " <> detail
    SchemaParseError(detail:) -> detail
    QueryReadError(path:, detail:) -> path <> ": " <> detail
    QueryParseError(detail:, ..) -> detail
    QueryAnalysisError(detail:) -> detail
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
    UnsupportedAnnotation(query_name:, command:, detail:) ->
      "Query " <> query_name <> " uses " <> command <> ": " <> detail
    WriteError(inner) -> writer.error_to_string(inner)
  }
}
