import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile
import sqlode/internal/codegen/adapter
import sqlode/internal/codegen/common
import sqlode/internal/codegen/models
import sqlode/internal/codegen/params
import sqlode/internal/codegen/queries
import sqlode/internal/config
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_analyzer/context
import sqlode/internal/query_ir
import sqlode/internal/query_parser
import sqlode/internal/query_validation
import sqlode/internal/schema_parser
import sqlode/internal/sql_paths
import sqlode/internal/type_mapping
import sqlode/internal/writer

pub type GenerateError {
  ConfigError(config.ConfigError)
  SchemaReadError(path: String, detail: String)
  SchemaParseFailed(schema_parser.ParseError)
  /// `strict_views` is set and the schema produced warnings.
  StrictViewsFailed(List(schema_parser.SchemaWarning))
  QueryReadError(path: String, detail: String)
  QueryParseFailed(query_parser.ParseError)
  QueryAnalysisFailed(error: context.AnalysisError, engine: model.Engine)
  ValidationFailed(query_validation.ValidationError)
  EnumValueRejected(type_mapping.EnumValueError)
  /// A table, column or parameter name does not turn into a Gleam
  /// name, typically because it is written in a non-Latin script.
  UnnamableIdentifier(kind: String, name: String, gleam_name: String)
  NoQueriesGenerated(
    output: String,
    parsed_query_count: Int,
    schema_table_count: Int,
    query_paths: List(String),
    schema_paths: List(String),
  )
  InvalidOutPath(path: String)
  WriteError(writer.WriteError)
  VendorRuntimeNotFound
}

/// Something worth telling the user that does not stop generation.
pub type Warning {
  SchemaWarning(schema_parser.SchemaWarning)
  /// A custom `gleam_type` without codec hooks is encoded and decoded
  /// as its underlying type.
  CustomTypeAlias(gleam_type: String, type_name: String, underlying: String)
}

/// What `run` produced: the written paths, or the error that stopped
/// it, and the warnings gathered on the way in either case.
pub type Generation {
  Generation(
    result: Result(List(String), GenerateError),
    warnings: List(Warning),
  )
}

pub fn run(config_path: String) -> Generation {
  case config.load(config_path) {
    Error(error) -> Generation(result: Error(ConfigError(error)), warnings: [])
    Ok(config) -> {
      let config_dir = filepath.directory_name(config_path)
      generate_config(resolve_config_paths(config, config_dir))
    }
  }
}

/// Resolve the paths in `config` against the directory of the config file,
/// as `generate` and `verify` both read them.
pub fn resolve_config_paths(
  config: model.Config,
  base_dir: String,
) -> model.Config {
  let sql =
    list.map(config.sql, fn(block) {
      let schema = list.map(block.schema, resolve_path(base_dir, _))
      let queries = list.map(block.queries, resolve_path(base_dir, _))
      let gleam =
        model.GleamOutput(
          ..block.gleam,
          out: resolve_path(base_dir, block.gleam.out),
        )
      model.SqlBlock(..block, schema:, queries:, gleam:)
    })
  model.Config(..config, sql:)
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

pub fn generate_config(config: model.Config) -> Generation {
  let #(files, warnings) = generate_blocks(naming.new(), config.sql, [], [])
  let result =
    result.try(files, fn(files) {
      writer.write_all(files) |> result.map_error(WriteError)
    })
  Generation(result:, warnings: list.unique(warnings))
}

/// Render every block, stopping at the first error. The warnings of
/// the blocks read so far are kept either way.
fn generate_blocks(
  naming_ctx: naming.NamingContext,
  blocks: List(model.SqlBlock),
  files: List(writer.GeneratedFile),
  warnings: List(Warning),
) -> #(Result(List(writer.GeneratedFile), GenerateError), List(Warning)) {
  case blocks {
    [] -> #(Ok(files), warnings)
    [block, ..rest] -> {
      let #(block_files, block_warnings) = generate_sql_block(naming_ctx, block)
      let warnings = list.append(warnings, block_warnings)
      case block_files {
        Ok(block_files) ->
          generate_blocks(
            naming_ctx,
            rest,
            list.append(files, block_files),
            warnings,
          )
        Error(error) -> #(Error(error), warnings)
      }
    }
  }
}

pub fn warning_to_string(warning: Warning) -> String {
  case warning {
    SchemaWarning(inner) -> schema_parser.warning_to_string(inner)
    CustomTypeAlias(gleam_type:, type_name:, underlying:) ->
      "Warning: custom gleam_type \""
      <> gleam_type
      <> "\" will use the encoder/decoder for the underlying \""
      <> underlying
      <> "\" type. Ensure \""
      <> type_name
      <> "\" is defined as a transparent type alias (e.g., pub type "
      <> type_name
      <> " = "
      <> underlying
      <> "), or provide explicit `encode` / `decode` codec hooks "
      <> "in `overrides.types` to support opaque types."
  }
}

fn generate_sql_block(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
) -> #(Result(List(writer.GeneratedFile), GenerateError), List(Warning)) {
  case validate_out_path(block.gleam.out) {
    Error(error) -> #(Error(error), [])
    Ok(Nil) ->
      case load_catalog(block) {
        Error(error) -> #(Error(error), [])
        Ok(#(catalog, warnings)) -> #(
          {
            use queries <- result.try(load_queries(naming_ctx, block))
            use analyzed <- result.try(
              query_analyzer.analyze_queries(
                block.engine,
                catalog,
                naming_ctx,
                queries,
              )
              |> result.map_error(QueryAnalysisFailed(_, block.engine)),
            )
            use analyzed <- result.try(check_analyzed(
              naming_ctx,
              block,
              catalog,
              analyzed,
            ))
            render_output_files(naming_ctx, block, catalog, queries, analyzed)
          },
          warnings,
        )
      }
  }
}

/// Read and parse the block's schema, then apply the type overrides.
/// Shared with `verify`, so both commands accept the same schemas.
pub fn load_catalog(
  block: model.SqlBlock,
) -> Result(#(model.Catalog, List(Warning)), GenerateError) {
  use entries <- result.try(read_sql_files(
    block.schema,
    "schema",
    SchemaReadError,
  ))
  use #(catalog, schema_warnings) <- result.try(
    schema_parser.parse_files(entries, block.engine)
    |> result.map_error(SchemaParseFailed),
  )
  use Nil <- result.try(case block.gleam.strict_views, schema_warnings {
    True, [_, ..] -> Error(StrictViewsFailed(schema_warnings))
    _, _ -> Ok(Nil)
  })
  use Nil <- result.try(
    type_mapping.validate_enum_values(catalog.enums)
    |> result.map_error(EnumValueRejected),
  )
  let #(catalog, override_warnings) =
    apply_type_overrides(catalog, block.overrides.type_overrides)
  Ok(#(
    catalog,
    list.append(list.map(schema_warnings, SchemaWarning), override_warnings),
  ))
}

/// Read and parse the block's query files and reject duplicate names.
pub fn load_queries(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
) -> Result(List(query_ir.TokenizedQuery), GenerateError) {
  use entries <- result.try(read_sql_files(
    block.queries,
    "query",
    QueryReadError,
  ))
  use queries <- result.try(
    entries
    |> list.try_map(fn(entry) {
      let #(path, content) = entry
      query_parser.parse_file(path, block.engine, naming_ctx, content)
      |> result.map_error(QueryParseFailed)
    })
    |> result.map(list.flatten),
  )
  use Nil <- result.try(
    query_validation.validate_no_duplicate_names(queries)
    |> result.map_error(ValidationFailed),
  )
  Ok(queries)
}

/// The checks that need analysed queries, then the column renames and
/// parameter name disambiguation that codegen relies on.
pub fn check_analyzed(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
  analyzed: List(model.AnalyzedQuery),
) -> Result(List(model.AnalyzedQuery), GenerateError) {
  use Nil <- result.try(validate_gleam_names(
    naming_ctx,
    catalog,
    analyzed,
    block.gleam.emit_exact_table_names,
  ))
  use Nil <- result.try(
    {
      use Nil <- result.try(query_validation.validate_unsupported_annotations(
        analyzed,
      ))
      use Nil <- result.try(query_validation.validate_array_engine_support(
        block.engine,
        analyzed,
      ))
      use Nil <- result.try(query_validation.validate_slice_placement(analyzed))
      case block.gleam.runtime {
        model.Native -> query_validation.validate_native_annotations(analyzed)
        model.Raw -> Ok(Nil)
      }
    }
    |> result.map_error(ValidationFailed),
  )
  analyzed
  |> apply_column_renames(block.overrides.column_renames)
  |> disambiguate_param_names
  |> Ok
}

/// Expand directories and read every `.sql` file. `kind` names the
/// files in the read error, which `read_error` wraps.
fn read_sql_files(
  paths: List(String),
  kind: String,
  read_error: fn(String, String) -> GenerateError,
) -> Result(List(#(String, String)), GenerateError) {
  use expanded <- result.try(sql_paths.expand(paths, read_error))
  list.try_map(expanded, fn(path) {
    simplifile.read(path)
    |> result.map(fn(content) { #(path, content) })
    |> result.map_error(fn(error) {
      read_error(
        path,
        "Failed to read "
          <> kind
          <> " file: "
          <> simplifile.describe_error(error),
      )
    })
  })
}

fn render_output_files(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
  queries: List(query_ir.TokenizedQuery),
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

      use base_files <- result.try(base_output_files(
        naming_ctx,
        block,
        analyzed,
        catalog,
        table_matches,
      ))

      case gleam.runtime {
        model.Raw -> Ok(base_files)
        model.Native ->
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

fn base_output_files(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
  catalog: model.Catalog,
  table_matches: Dict(String, String),
) -> Result(List(writer.GeneratedFile), GenerateError) {
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
      content: queries.render(
        naming_ctx,
        block,
        analyzed,
        table_matches,
        gleam.emit_exact_table_names,
      ),
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
          Ok(
            list.append(files_with_models, [
              writer.GeneratedFile(
                directory: out,
                path: "runtime.gleam",
                content: source,
              ),
            ]),
          )
        Error(_) -> Error(VendorRuntimeNotFound)
      }
    False -> Ok(files_with_models)
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

fn collect_referenced_tables(
  queries: List(model.AnalyzedQuery),
) -> List(String) {
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

/// Apply the `overrides.types` entries to the catalog's columns. A
/// column override wins over a database-type override.
fn apply_type_overrides(
  catalog: model.Catalog,
  overrides: List(model.TypeOverride),
) -> #(model.Catalog, List(Warning)) {
  case overrides {
    [] -> #(catalog, [])
    _ -> {
      let #(warnings, tables) =
        list.map_fold(catalog.tables, [], fn(warnings, table) {
          let #(warnings, columns) =
            list.map_fold(table.columns, warnings, fn(warnings, col) {
              let override =
                find_column_override(table.name, col.name, overrides)
                |> result.lazy_or(fn() {
                  find_db_type_override(
                    col.scalar_type,
                    col.nullable,
                    overrides,
                  )
                })
              case override {
                Error(Nil) -> #(warnings, col)
                Ok(#(gleam_type, codec)) -> {
                  let #(scalar_type, warning) =
                    gleam_type_to_scalar(gleam_type, codec, col.scalar_type)
                  let warnings = case warning {
                    option.Some(warning) -> [warning, ..warnings]
                    option.None -> warnings
                  }
                  #(warnings, model.Column(..col, scalar_type:))
                }
              }
            })
          #(warnings, model.Table(..table, columns:))
        })
      #(model.Catalog(..catalog, tables:), list.reverse(warnings))
    }
  }
}

fn find_column_override(
  table_name: String,
  column_name: String,
  overrides: List(model.TypeOverride),
) -> Result(#(String, option.Option(model.CodecHooks)), Nil) {
  list.find_map(overrides, fn(override) {
    case override {
      model.ColumnOverride(table:, column:, gleam_type:, codec:) ->
        case
          string.lowercase(table) == string.lowercase(table_name)
          && string.lowercase(column) == string.lowercase(column_name)
        {
          True -> Ok(#(gleam_type, codec))
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
) -> Result(#(String, option.Option(model.CodecHooks)), Nil) {
  let type_name = type_mapping.scalar_type_to_db_name(scalar_type)

  list.find_map(overrides, fn(override) {
    case override {
      model.DbTypeOverride(db_type:, gleam_type:, nullable:, codec:) ->
        case string.lowercase(db_type) == type_name {
          True ->
            case nullable {
              option.None -> Ok(#(gleam_type, codec))
              option.Some(n) ->
                case n == is_nullable {
                  True -> Ok(#(gleam_type, codec))
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
  codec: option.Option(model.CodecHooks),
  underlying: model.ScalarType,
) -> #(model.ScalarType, option.Option(Warning)) {
  case string.lowercase(gleam_type) {
    "int" -> #(model.IntType, option.None)
    "float" -> #(model.FloatType, option.None)
    "bool" -> #(model.BoolType, option.None)
    "string" -> #(model.StringType, option.None)
    "bitarray" -> #(model.BytesType, option.None)
    _ -> {
      let #(module, type_name) = parse_module_qualified_type(gleam_type)
      // Suppress the transparent-alias warning when the user supplied
      // explicit codec hooks — that's the documented escape hatch for
      // opaque domain types (issue #529). Without hooks, keep the
      // existing warning so users aren't surprised when the generated
      // code calls primitive encoders directly on a wrapped value.
      let warning = case codec {
        option.Some(_) -> option.None
        option.None ->
          option.Some(CustomTypeAlias(
            gleam_type:,
            type_name:,
            underlying: type_mapping.scalar_type_to_gleam_type(
              underlying,
              model.StringMapping,
            ),
          ))
      }
      #(
        model.CustomType(name: type_name, module:, underlying:, codec:),
        warning,
      )
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

/// Disambiguate `field_name` collisions inside each query's params.
/// `WHERE x >= ? AND x < ?` produces two params both named `x`,
/// which surfaces in codegen as duplicated record fields and labelled
/// arguments — neither is valid Gleam. We give the second and later
/// occurrences a `_<n>` suffix (`x`, `x_2`, `x_3`, …) so the
/// generated record / function head compiles. Single occurrences are
/// untouched, so existing queries that reference each column once
/// keep their names. Public so the test suite can pin the rule
/// without going through the full generate pipeline. (#472)
@internal
pub fn disambiguate_param_names(
  queries: List(model.AnalyzedQuery),
) -> List(model.AnalyzedQuery) {
  list.map(queries, disambiguate_query_params)
}

fn disambiguate_query_params(
  query: model.AnalyzedQuery,
) -> model.AnalyzedQuery {
  let counts =
    list.fold(query.params, dict.new(), fn(acc, p) {
      dict.upsert(acc, p.field_name, fn(prev) {
        case prev {
          option.Some(n) -> n + 1
          option.None -> 1
        }
      })
    })

  let #(_, renamed_reversed) =
    list.fold(query.params, #(dict.new(), []), fn(acc, p) {
      let #(seen, out) = acc
      case dict.get(counts, p.field_name) {
        Ok(n) if n > 1 -> {
          let occurrence = case dict.get(seen, p.field_name) {
            Ok(prev) -> prev + 1
            Error(_) -> 1
          }
          let new_seen = dict.insert(seen, p.field_name, occurrence)
          let new_name = case occurrence {
            // First occurrence keeps the original name; later
            // occurrences pick up the `_<n>` suffix.
            1 -> p.field_name
            _ -> p.field_name <> "_" <> int.to_string(occurrence)
          }
          let renamed = model.QueryParam(..p, field_name: new_name)
          #(new_seen, [renamed, ..out])
        }
        _ -> #(seen, [p, ..out])
      }
    })
  model.AnalyzedQuery(..query, params: list.reverse(renamed_reversed))
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

/// The generated modules import each other by `out`'s module path, so
/// it must not be absolute or relative, and must not keep a `..`
/// segment that the path resolution could not fold away.
pub fn validate_out_path(out: String) -> Result(Nil, GenerateError) {
  let module_path = common.out_to_module_path(out)
  case
    string.starts_with(module_path, "/")
    || string.starts_with(module_path, ".")
    || list.contains(string.split(module_path, "/"), "..")
  {
    True -> Error(InvalidOutPath(path: out))
    False -> Ok(Nil)
  }
}

/// Every table, column and parameter becomes a Gleam type, field or
/// label. Stop with a clear error when one would not be a valid Gleam
/// name instead of writing code that does not compile.
fn validate_gleam_names(
  naming_ctx: naming.NamingContext,
  catalog: model.Catalog,
  analyzed: List(model.AnalyzedQuery),
  emit_exact_table_names: Bool,
) -> Result(Nil, GenerateError) {
  let check = fn(kind, name, gleam_name, valid) {
    case valid {
      True -> Ok(Nil)
      False -> Error(UnnamableIdentifier(kind:, name:, gleam_name:))
    }
  }
  let label = fn(kind, name) {
    let gleam_name = naming.to_snake_case(naming_ctx, name)
    check(kind, name, gleam_name, naming.is_label(gleam_name))
  }
  use Nil <- result.try(
    list.try_each(catalog.tables, fn(table) {
      let type_name =
        naming.table_type_name(naming_ctx, table.name, emit_exact_table_names)
      use Nil <- result.try(check(
        "table",
        table.name,
        type_name,
        naming.is_type_name(type_name),
      ))
      list.try_each(table.columns, fn(column) {
        label("column of table " <> table.name, column.name)
      })
    }),
  )
  list.try_each(analyzed, fn(query) {
    let kind = "column of query " <> query.base.name
    use Nil <- result.try(
      list.try_each(query.params, fn(param) {
        label("parameter of query " <> query.base.name, param.field_name)
      }),
    )
    list.try_each(query.result_columns, fn(item) {
      case item {
        model.ScalarResult(column) -> label(kind, column.name)
        model.EmbeddedResult(embedded) -> label(kind, embedded.name)
      }
    })
  })
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
  use <- bool.guard(!model.is_result_command(query.base.command), Error(Nil))

  // Queries with embedded columns never match a single table
  let has_embed =
    list.any(query.result_columns, fn(col) {
      case col {
        model.EmbeddedResult(..) -> True
        model.ScalarResult(..) -> False
      }
    })
  use <- bool.guard(has_embed, Error(Nil))

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
  use <- bool.guard(!all_same_table, Error(Nil))

  // The table must exist and columns must match exactly
  use table <- result.try(find_table(catalog, table_name))
  use <- bool.guard(
    !columns_match(query.result_columns, table.columns),
    Error(Nil),
  )

  Ok(#(
    query.base.function_name,
    naming.table_type_name(naming_ctx, table_name, emit_exact_table_names),
  ))
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
    SchemaReadError(path:, detail:) -> "SQD2001: " <> path <> ": " <> detail
    SchemaParseFailed(inner) -> schema_parser.error_to_string(inner)
    StrictViewsFailed(warnings) ->
      "SQD2005: strict_views is enabled but the schema produced resolution warnings:\n  "
      <> string.join(
        list.map(warnings, schema_parser.warning_to_string),
        "\n  ",
      )
    QueryReadError(path:, detail:) -> "SQD3001: " <> path <> ": " <> detail
    QueryParseFailed(inner) -> query_parser.error_to_string(inner)
    QueryAnalysisFailed(error:, engine:) ->
      context.analysis_error_to_string(error, engine)
    ValidationFailed(inner) -> query_validation.error_to_string(inner)
    EnumValueRejected(inner) -> type_mapping.enum_value_error_to_string(inner)
    UnnamableIdentifier(kind:, name:, gleam_name:) ->
      "SQD5005: "
      <> kind
      <> " \""
      <> name
      <> "\" cannot become a Gleam name (it would be \""
      <> gleam_name
      <> "\"). Gleam names use ASCII letters, digits and '_'; rename it, or give the column an ASCII alias with AS in the query"
    NoQueriesGenerated(
      output:,
      parsed_query_count:,
      schema_table_count:,
      query_paths:,
      schema_paths:,
    ) ->
      "SQD5001: No queries were generated for output directory: "
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
    InvalidOutPath(path:) ->
      "SQD5002: Invalid output path \""
      <> path
      <> "\": produces an invalid Gleam module path. Use a relative path under src/ (e.g., \"src/db\")"
    WriteError(inner) -> writer.error_to_string(inner)
    VendorRuntimeNotFound ->
      "SQD5004: vendor_runtime is enabled but the sqlode/runtime source file could not be found. Tried: src/sqlode/runtime.gleam, build/packages/sqlode/src/sqlode/runtime.gleam, build/dev/erlang/sqlode/src/sqlode/runtime.gleam"
  }
}
