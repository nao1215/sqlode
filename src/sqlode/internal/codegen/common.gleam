import gleam/list
import gleam/option
import gleam/result
import gleam/string
import sqlode/internal/codegen/builder
import sqlode/internal/model
import sqlode/internal/type_mapping

pub fn has_slices(params: List(model.QueryParam)) -> Bool {
  list.any(params, fn(p) { p.is_list })
}

pub fn queries_have_slices(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) { has_slices(query.params) })
}

/// Wrap the base decoder for `EnumType` and `SetType` columns so the
/// decoded value reaches the consuming record as the generated sum
/// type (or list of sum-type values for SET) rather than the raw
/// wire string. `fallback` is the decoder to use for every other
/// scalar type (adapter-specific in the caller — e.g. pog's
/// `decode.bool` vs sqlight's int-to-bool adapter).
pub fn render_enum_or_set_decoder(
  scalar_type: model.ScalarType,
  fallback: fn(model.ScalarType) -> String,
) -> String {
  case scalar_type {
    // `decode.failure` requires a placeholder of the target type for
    // type inference — it is never returned to callers. For ENUMs we
    // call the generated `<name>_default()` helper; for SETs `[]` is
    // a natural empty fallback. The error message includes the
    // actual received value so schema-drift mismatches are diagnosable.
    model.EnumType(enum_name) ->
      "decode.then(decode.string, fn(s) { case models."
      <> type_mapping.enum_from_string_fn(enum_name)
      <> "(s) { Ok(v) -> decode.success(v) Error(_) -> decode.failure(models."
      <> type_mapping.enum_default_fn(enum_name)
      <> "(), \"known "
      <> enum_name
      <> " variant, got '\" <> s <> \"'\") } })"
    model.SetType(set_name) ->
      "decode.then(decode.string, fn(s) { case models."
      <> type_mapping.set_from_string_fn(set_name)
      <> "(s) { Ok(v) -> decode.success(v) Error(_) -> decode.failure([], \"known "
      <> set_name
      <> " set value, got '\" <> s <> \"'\") } })"
    _ -> fallback(scalar_type)
  }
}

/// Render a param / record field's Gleam type for generated modules
/// that are NOT `models.gleam` itself (currently `params.gleam` and
/// `queries.gleam`). They reach the generated `EnumType` / `SetType`
/// definitions and rich-scalar aliases / wrappers through a plain
/// `import db/models`, so every external reference must be qualified
/// with `models.` — the bare names only work inside `models.gleam`
/// where the types are declared. `ArrayType` recurses so arrays of
/// enum / set / rich scalars stay qualified.
pub fn qualified_field_type(
  scalar_type: model.ScalarType,
  type_mapping_mode: model.TypeMapping,
) -> String {
  case scalar_type {
    model.EnumType(_) ->
      "models."
      <> type_mapping.scalar_type_to_gleam_type(scalar_type, type_mapping_mode)
    model.SetType(name) ->
      "List(models." <> type_mapping.set_value_type_name(name) <> ")"
    model.ArrayType(element) ->
      "List(" <> qualified_field_type(element, type_mapping_mode) <> ")"
    _ ->
      case needs_models_prefix_for_rich_type(scalar_type, type_mapping_mode) {
        True ->
          "models."
          <> type_mapping.scalar_type_to_gleam_type(
            scalar_type,
            type_mapping_mode,
          )
        False ->
          type_mapping.scalar_type_to_gleam_type(scalar_type, type_mapping_mode)
      }
  }
}

/// Rich scalars (`UUID` / `TIMESTAMP` / `DATE` / ...) only acquire a
/// distinct Gleam type under `rich` / `strong` mapping — the string
/// mapping keeps them as plain `String`. Under either rich mapping
/// mode, the resulting type (an alias or a wrapper) lives in
/// `models.gleam` and must be qualified when referenced from
/// `params.gleam` / `queries.gleam`.
fn needs_models_prefix_for_rich_type(
  scalar_type: model.ScalarType,
  type_mapping_mode: model.TypeMapping,
) -> Bool {
  case type_mapping_mode {
    model.RichMapping | model.StrongMapping ->
      type_mapping.is_rich_type(scalar_type)
    model.StringMapping -> False
  }
}

pub fn queries_have_enum_params(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) {
    list.any(query.params, fn(param) {
      case param.scalar_type {
        model.EnumType(_) | model.SetType(_) -> True
        _ -> False
      }
    })
  })
}

pub fn queries_have_enums(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) {
    list.any(query.params, fn(param) {
      case param.scalar_type {
        model.EnumType(_) | model.SetType(_) -> True
        _ -> False
      }
    })
    || list.any(query.result_columns, fn(col) {
      case col {
        model.ScalarResult(model.ResultColumn(
          scalar_type: model.EnumType(_),
          ..,
        ))
        | model.ScalarResult(model.ResultColumn(
            scalar_type: model.SetType(_),
            ..,
          )) -> True
        _ -> False
      }
    })
  })
}

/// Collect import statements for module-qualified custom types from scalar types.
pub fn custom_type_imports(scalar_types: List(model.ScalarType)) -> List(String) {
  scalar_types
  |> list.filter_map(fn(st) {
    case st {
      model.CustomType(name, option.Some(module), _) ->
        Ok("import " <> module <> ".{type " <> name <> "}")
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

/// Collect all scalar types from query result columns.
pub fn result_scalar_types(
  queries: List(model.AnalyzedQuery),
) -> List(model.ScalarType) {
  list.flat_map(queries, fn(query) {
    list.filter_map(query.result_columns, fn(col) {
      case col {
        model.ScalarResult(model.ResultColumn(scalar_type:, ..)) ->
          Ok(scalar_type)
        model.EmbeddedResult(model.EmbeddedColumn(columns:, ..)) ->
          case
            list.find_map(columns, fn(c) {
              case c.scalar_type {
                model.CustomType(..) -> Ok(c.scalar_type)
                _ -> Error(Nil)
              }
            })
          {
            Ok(st) -> Ok(st)
            Error(_) -> Error(Nil)
          }
      }
    })
  })
}

/// Collect all scalar types from query params.
pub fn param_scalar_types(
  queries: List(model.AnalyzedQuery),
) -> List(model.ScalarType) {
  list.flat_map(queries, fn(query) {
    list.map(query.params, fn(p) { p.scalar_type })
  })
}

/// Collect all scalar types from catalog tables.
pub fn catalog_scalar_types(catalog: model.Catalog) -> List(model.ScalarType) {
  list.flat_map(catalog.tables, fn(table) {
    list.map(table.columns, fn(col) { col.scalar_type })
  })
}

pub fn escape_string(input: String) -> String {
  input
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// Derive the Gleam module path from the output directory.
/// Strips the "src/" prefix so imports match the actual file location.
/// e.g. "src/db" -> "db", "/abs/path/src/db" -> "db"
pub fn out_to_module_path(out: String) -> String {
  case string.starts_with(out, "src/") {
    True -> string.drop_start(out, 4)
    False ->
      string.split(out, "/src/")
      |> list.last
      |> result.unwrap(out)
  }
}

/// Import path used by generated modules for the sqlode runtime. When
/// `gleam.vendor_runtime` is enabled, the runtime source is written
/// into `<out>/runtime.gleam` and the generated code points at that
/// local copy (e.g. `db/runtime`). Otherwise the shared
/// `sqlode/runtime` dependency is used.
pub fn runtime_import_path(gleam: model.GleamOutput) -> String {
  case gleam.vendor_runtime {
    True -> out_to_module_path(gleam.out) <> "/runtime"
    False -> "sqlode/runtime"
  }
}

/// Render a single-constructor Gleam type declaration.
///
/// gleam_type("UserId", "Int") →
///   "pub type UserId {
///      UserId(Int)
///    }"
pub fn gleam_type(name: String, body: String) -> String {
  builder.concat([
    builder.line("pub type " <> name <> " {"),
    builder.line("  " <> name <> "(" <> body <> ")"),
    builder.line("}"),
  ])
  |> builder.render
}

/// Render a Gleam function declaration as a single string.
///
/// gleam_fn("double", "x: Int", "Int", "x * 2") →
///   "pub fn double(x: Int) -> Int {
///      x * 2
///    }"
pub fn gleam_fn(
  name: String,
  params: String,
  return_type: String,
  body: String,
) -> String {
  builder.concat([
    builder.line(
      "pub fn " <> name <> "(" <> params <> ") -> " <> return_type <> " {",
    ),
    builder.line("  " <> body),
    builder.line("}"),
  ])
  |> builder.render
}
