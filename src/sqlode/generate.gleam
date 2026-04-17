import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile
import sqlode/codegen/adapter
import sqlode/codegen/common
import sqlode/codegen/models
import sqlode/codegen/params
import sqlode/codegen/queries
import sqlode/config
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/runtime
import sqlode/schema_parser
import sqlode/type_mapping
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
  DuplicateQueryName(name: String, paths: List(String))
  UnsupportedAnnotation(query_name: String, command: String, detail: String)
  InvalidOutPath(path: String)
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
  use Nil <- result.try(validate_out_path(block.gleam.out))
  use catalog <- result.try(load_and_prepare_catalog(block))
  use #(queries, analyzed) <- result.try(load_and_analyze_queries(
    naming_ctx,
    block,
    catalog,
  ))
  render_output_files(naming_ctx, block, catalog, queries, analyzed)
}

fn load_and_prepare_catalog(
  block: model.SqlBlock,
) -> Result(model.Catalog, GenerateError) {
  use raw_catalog <- result.try(load_catalog(block.schema, block.engine))
  Ok(apply_type_overrides(raw_catalog, block.overrides.type_overrides))
}

fn load_and_analyze_queries(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
) -> Result(
  #(List(model.ParsedQuery), List(model.AnalyzedQuery)),
  GenerateError,
) {
  use queries <- result.try(load_queries(naming_ctx, block))
  use analyzed <- result.try(
    query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, queries)
    |> result.map_error(fn(error) {
      QueryAnalysisError(detail: query_analyzer.analysis_error_to_string(error))
    }),
  )
  use Nil <- result.try(validate_unsupported_annotations(analyzed))
  let analyzed = apply_column_renames(analyzed, block.overrides.column_renames)
  Ok(#(queries, analyzed))
}

fn render_output_files(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
  queries: List(model.ParsedQuery),
  analyzed: List(model.AnalyzedQuery),
) -> Result(List(writer.GeneratedFile), GenerateError) {
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
      let table_matches =
        compute_table_matches(
          naming_ctx,
          catalog,
          analyzed,
          gleam.emit_exact_table_names,
        )

      let base_files =
        base_output_files(naming_ctx, block, analyzed, catalog, table_matches)

      case gleam.runtime {
        model.Raw -> Ok(base_files)
        model.Native -> {
          use Nil <- result.try(validate_native_annotations(analyzed))
          Ok(
            list.append(base_files, [
              writer.GeneratedFile(
                directory: out,
                path: adapter_filename(block.engine),
                content: adapter.render(
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

fn base_output_files(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
  catalog: model.Catalog,
  table_matches: Dict(String, String),
) -> List(writer.GeneratedFile) {
  let model.SqlBlock(gleam:, ..) = block
  let model.GleamOutput(out:, ..) = gleam

  let has_row_types =
    list.any(analyzed, fn(query) {
      model.is_result_command(query.base.command)
      && !list.is_empty(query.result_columns)
    })
  let has_models = has_row_types || !list.is_empty(catalog.tables)

  let files = [
    writer.GeneratedFile(
      directory: out,
      path: "params.gleam",
      content: params.render(
        naming_ctx,
        analyzed,
        gleam.type_mapping,
        common.out_to_module_path(out),
        common.runtime_import_path(gleam),
      ),
    ),
    writer.GeneratedFile(
      directory: out,
      path: "queries.gleam",
      content: queries.render(naming_ctx, block, analyzed),
    ),
  ]

  let files_with_models = case has_models {
    True -> {
      let effective_catalog = case gleam.omit_unused_models {
        True -> prune_catalog_to_used(catalog, analyzed)
        False -> catalog
      }
      list.append(files, [
        writer.GeneratedFile(
          directory: out,
          path: "models.gleam",
          content: models.render(
            naming_ctx,
            effective_catalog,
            analyzed,
            table_matches,
            gleam.type_mapping,
            gleam.emit_exact_table_names,
          ),
        ),
      ])
    }
    False -> files
  }

  case gleam.vendor_runtime {
    True ->
      case read_runtime_source() {
        Ok(source) ->
          list.append(files_with_models, [
            writer.GeneratedFile(
              directory: out,
              path: "runtime.gleam",
              content: source,
            ),
          ])
        Error(_) -> files_with_models
      }
    False -> files_with_models
  }
}

/// Return the `sqlode/runtime` module source. Tries known paths in
/// order: a development checkout (when sqlode itself runs the
/// generator), then the extracted hex package layout a user project
/// would have after `gleam add sqlode`. When none are found, emit
/// nothing rather than a broken file — the flag still defaults off,
/// so a user who opted in will at least notice that the file they
/// asked for is missing.
fn read_runtime_source() -> Result(String, Nil) {
  let candidates = [
    "src/sqlode/runtime.gleam",
    "build/packages/sqlode/src/sqlode/runtime.gleam",
    "build/dev/erlang/sqlode/src/sqlode/runtime.gleam",
  ]
  list.find_map(candidates, fn(path) {
    case simplifile.read(path) {
      Ok(content) -> Ok(content)
      Error(_) -> Error(Nil)
    }
  })
}

/// Drop tables and enums from the catalog that no generated query
/// actually references. A table is "used" when at least one analysed
/// query names it as a `source_table` on a scalar result column, lists
/// it via `EmbeddedResult`, or is carried by a `table_matches` alias
/// (SELECT * on an exact table). An enum is "used" when one of the
/// retained tables owns a column of that enum type, or when a query
/// result column / parameter has that enum type.
fn prune_catalog_to_used(
  catalog: model.Catalog,
  queries: List(model.AnalyzedQuery),
) -> model.Catalog {
  let referenced_tables = collect_referenced_tables(queries)

  let retained_tables =
    list.filter(catalog.tables, fn(t) {
      list.contains(referenced_tables, t.name)
    })

  let referenced_enums = collect_referenced_enums(retained_tables, queries)
  let retained_enums =
    list.filter(catalog.enums, fn(e) { list.contains(referenced_enums, e.name) })

  model.Catalog(tables: retained_tables, enums: retained_enums)
}

fn collect_referenced_tables(queries: List(model.AnalyzedQuery)) -> List(String) {
  queries
  |> list.flat_map(fn(query) {
    list.flat_map(query.result_columns, fn(item) {
      case item {
        model.ScalarResult(col) ->
          case col.source_table {
            option.Some(name) -> [name]
            option.None -> []
          }
        model.EmbeddedResult(embed) -> [embed.table_name]
      }
    })
  })
  |> list.unique
}

fn collect_referenced_enums(
  retained_tables: List(model.Table),
  queries: List(model.AnalyzedQuery),
) -> List(String) {
  let from_tables =
    retained_tables
    |> list.flat_map(fn(t) { t.columns })
    |> list.filter_map(fn(c) { enum_name(c.scalar_type) })

  let from_query_columns =
    queries
    |> list.flat_map(fn(q) {
      list.flat_map(q.result_columns, fn(item) {
        case item {
          model.ScalarResult(col) ->
            case enum_name(col.scalar_type) {
              Ok(name) -> [name]
              Error(Nil) -> []
            }
          model.EmbeddedResult(embed) ->
            list.filter_map(embed.columns, fn(c) { enum_name(c.scalar_type) })
        }
      })
    })

  let from_query_params =
    queries
    |> list.flat_map(fn(q) {
      list.filter_map(q.params, fn(p) { enum_name(p.scalar_type) })
    })

  list.append(from_tables, list.append(from_query_columns, from_query_params))
  |> list.unique
}

fn enum_name(scalar_type: model.ScalarType) -> Result(String, Nil) {
  case scalar_type {
    model.EnumType(name) -> Ok(name)
    model.ArrayType(inner) -> enum_name(inner)
    _ -> Error(Nil)
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

fn load_catalog(
  paths: List(String),
  engine: model.Engine,
) -> Result(model.Catalog, GenerateError) {
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

  use #(catalog, warnings) <- result.try(
    schema_parser.parse_files_with_engine(entries, engine)
    |> result.map_error(fn(error) {
      SchemaParseError(detail: schema_parser.error_to_string(error))
    }),
  )

  list.each(warnings, fn(w) {
    io.println_error(schema_parser.warning_to_string(w))
  })

  Ok(catalog)
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
  |> result.try(validate_no_duplicate_query_names)
}

fn validate_no_duplicate_query_names(
  queries: List(model.ParsedQuery),
) -> Result(List(model.ParsedQuery), GenerateError) {
  let grouped =
    list.group(queries, fn(q) { q.name })
    |> dict.to_list
    |> list.filter(fn(entry) { list.length(entry.1) > 1 })

  case grouped {
    [] -> Ok(queries)
    [#(name, dupes), ..] -> {
      let paths =
        dupes
        |> list.map(fn(q) { q.source_path })
        |> list.unique
      Error(DuplicateQueryName(name:, paths:))
    }
  }
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
  let type_name = type_mapping.scalar_type_to_db_name(scalar_type)

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
      let #(module, type_name) = parse_module_qualified_type(gleam_type)
      let underlying_name =
        type_mapping.scalar_type_to_gleam_type(underlying, model.StringMapping)
      io.println_error(
        "Warning: custom gleam_type \""
        <> gleam_type
        <> "\" will use the encoder/decoder for the underlying \""
        <> underlying_name
        <> "\" type. Ensure \""
        <> type_name
        <> "\" is defined as a transparent type alias (e.g., pub type "
        <> type_name
        <> " = "
        <> underlying_name
        <> "). Opaque types are not supported.",
      )
      model.CustomType(name: type_name, module:, underlying:)
    }
  }
}

fn parse_module_qualified_type(
  gleam_type: String,
) -> #(option.Option(String), String) {
  case string.split_once(gleam_type, ".") {
    Ok(#(module_path, type_name)) -> #(option.Some(module_path), type_name)
    Error(_) -> #(option.None, gleam_type)
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
          list.map(query.result_columns, fn(item) {
            case item {
              model.ScalarResult(col) ->
                case find_column_rename(col.name, col.source_table, renames) {
                  Ok(new_name) ->
                    model.ScalarResult(
                      model.ResultColumn(..col, name: new_name),
                    )
                  Error(_) -> item
                }
              model.EmbeddedResult(..) -> item
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

fn validate_out_path(out: String) -> Result(Nil, GenerateError) {
  let module_path = common.out_to_module_path(out)
  case
    string.starts_with(module_path, "/") || string.starts_with(module_path, ".")
  {
    True -> Error(InvalidOutPath(path: out))
    False -> Ok(Nil)
  }
}

fn validate_unsupported_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, GenerateError) {
  let unsupported = fn(command: runtime.QueryCommand) -> Bool {
    case command {
      runtime.QueryBatchOne
      | runtime.QueryBatchMany
      | runtime.QueryBatchExec
      | runtime.QueryCopyFrom -> True
      _ -> False
    }
  }
  case list.find(queries, fn(q) { unsupported(q.base.command) }) {
    Ok(q) -> {
      let #(command, alternative) = case q.base.command {
        runtime.QueryBatchOne -> #(":batchone", ":one")
        runtime.QueryBatchMany -> #(":batchmany", ":many")
        runtime.QueryBatchExec -> #(":batchexec", ":exec")
        runtime.QueryCopyFrom -> #(":copyfrom", ":exec")
        _ -> #("", ":exec")
      }
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: command,
        detail: command
          <> " is not yet supported. Use "
          <> alternative
          <> " instead, or add '-- sqlode:skip' before the annotation to bypass this query",
      ))
    }
    Error(_) -> Ok(Nil)
  }
}

fn validate_native_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, GenerateError) {
  case list.find(queries, fn(q) { q.base.command == runtime.QueryExecResult }) {
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
        model.EmbeddedResult(..) -> True
        model.ScalarResult(..) -> False
      }
    })
  use <- guard_result(!has_embed)

  // Extract the source table from the first result column
  use table_name <- result.try(case query.result_columns {
    [
      model.ScalarResult(model.ResultColumn(source_table: option.Some(name), ..)),
      ..
    ] -> Ok(name)
    _ -> Error(Nil)
  })

  // All result columns must come from the same table
  let all_same_table =
    list.all(query.result_columns, fn(col) {
      case col {
        model.ScalarResult(model.ResultColumn(source_table: src, ..)) ->
          src == option.Some(table_name)
        model.EmbeddedResult(..) -> False
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
  result_columns: List(model.ResultItem),
  table_columns: List(model.Column),
) -> Bool {
  case list.length(result_columns) == list.length(table_columns) {
    False -> False
    True ->
      list.zip(result_columns, table_columns)
      |> list.all(fn(pair) {
        let #(rc, tc) = pair
        case rc {
          model.ScalarResult(model.ResultColumn(
            name:,
            scalar_type:,
            nullable:,
            ..,
          )) ->
            string.lowercase(name) == string.lowercase(tc.name)
            && scalar_type == tc.scalar_type
            && nullable == tc.nullable
          model.EmbeddedResult(..) -> False
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
    DuplicateQueryName(name:, paths:) ->
      "duplicate query name \""
      <> name
      <> "\" found in: "
      <> string.join(paths, ", ")
    UnsupportedAnnotation(query_name:, command:, detail:) ->
      "Query " <> query_name <> " uses " <> command <> ": " <> detail
    InvalidOutPath(path:) ->
      "Invalid output path \""
      <> path
      <> "\": produces an invalid Gleam module path. Use a relative path under src/ (e.g., \"src/db\")"
    WriteError(inner) -> writer.error_to_string(inner)
  }
}
