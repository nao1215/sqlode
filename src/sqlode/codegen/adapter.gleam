import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import sqlode/codegen/builder
import sqlode/codegen/common
import sqlode/model
import sqlode/naming
import sqlode/runtime
import sqlode/type_mapping

type AdapterConfig {
  AdapterConfig(
    library_import: String,
    connection_type: String,
    error_type: String,
    value_function: fn(model.ScalarType) -> String,
    decoder_function: fn(model.ScalarType) -> String,
    render_params: fn(List(model.QueryParam), String) -> String,
    render_query_call: fn(
      String,
      String,
      String,
      String,
      List(model.QueryParam),
    ) ->
      List(String),
    render_one_result: fn() -> List(String),
    render_many_result: fn() -> List(String),
    render_exec_rows_result: fn() -> List(String),
    render_exec_last_id: fn(String, String, String, List(model.QueryParam)) ->
      List(String),
    placeholder_prefix: String,
    /// Gleam source text for a `value_to_<driver>` helper that converts
    /// a `runtime.Value` into this driver's parameter type. Emitted
    /// once per adapter file; each generated query function folds
    /// `runtime.prepare(q, p)` through this helper instead of
    /// re-encoding parameters per call.
    value_to_driver_helper: String,
    /// Decoder source text that `render_adapter_exec_rows` passes
    /// through to `render_query_call`. pog/sqlight rely on a follow-up
    /// `SELECT` for the affected-row count, so they decode `Nil`;
    /// shork's `Returned` surfaces the count as column index 1 of the
    /// synthetic INSERT/UPDATE/DELETE row, so it needs a real decoder.
    exec_rows_decoder: String,
  )
}

type RenderContext {
  RenderContext(
    naming_ctx: naming.NamingContext,
    config: AdapterConfig,
    table_matches: Dict(String, String),
    emit_sql_as_comment: Bool,
    emit_exact_table_names: Bool,
    type_mapping: model.TypeMapping,
  )
}

pub fn render(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  queries: List(model.AnalyzedQuery),
  table_matches: Dict(String, String),
) -> String {
  case block.engine {
    model.PostgreSQL ->
      render_adapter(
        naming_ctx,
        block,
        queries,
        table_matches,
        pog_adapter_config(),
      )
    model.SQLite ->
      render_adapter(
        naming_ctx,
        block,
        queries,
        table_matches,
        sqlight_adapter_config(),
      )
    model.MySQL ->
      render_adapter(
        naming_ctx,
        block,
        queries,
        table_matches,
        shork_adapter_config(),
      )
  }
}

// ============================================================
// Engine configs
// ============================================================

fn pog_adapter_config() -> AdapterConfig {
  AdapterConfig(
    library_import: "import pog",
    connection_type: "pog.Connection",
    error_type: "pog.QueryError",
    value_function: type_mapping.scalar_type_to_value_function(
      model.PostgreSQL,
      _,
    ),
    decoder_function: type_mapping.scalar_type_to_decoder(model.PostgreSQL, _),
    render_params: render_pog_params,
    render_query_call: render_pog_query_call,
    render_one_result: render_pog_one_result,
    render_many_result: render_pog_many_result,
    render_exec_rows_result: render_pog_exec_rows_result,
    render_exec_last_id: render_pog_exec_last_id,
    placeholder_prefix: "$",
    value_to_driver_helper: pog_value_to_driver_helper(),
    exec_rows_decoder: "decode.success(Nil)",
  )
}

fn sqlight_adapter_config() -> AdapterConfig {
  AdapterConfig(
    library_import: "import sqlight",
    connection_type: "sqlight.Connection",
    error_type: "sqlight.Error",
    value_function: type_mapping.scalar_type_to_value_function(model.SQLite, _),
    decoder_function: type_mapping.scalar_type_to_decoder(model.SQLite, _),
    render_params: render_sqlight_params,
    render_query_call: render_sqlight_query_call,
    render_one_result: render_sqlight_one_result,
    render_many_result: render_sqlight_many_result,
    render_exec_rows_result: render_sqlight_exec_rows_result,
    render_exec_last_id: render_sqlight_exec_last_id,
    placeholder_prefix: "?",
    value_to_driver_helper: sqlight_value_to_driver_helper(),
    exec_rows_decoder: "decode.success(Nil)",
  )
}

fn pog_value_to_driver_helper() -> String {
  "fn value_to_pog(value: runtime.Value) -> pog.Value {
  case value {
    runtime.SqlNull -> pog.null()
    runtime.SqlString(v) -> pog.text(v)
    runtime.SqlInt(v) -> pog.int(v)
    runtime.SqlFloat(v) -> pog.float(v)
    runtime.SqlBool(v) -> pog.bool(v)
    runtime.SqlBytes(v) -> pog.bytea(v)
    runtime.SqlArray(vs) -> pog.array(value_to_pog, vs)
  }
}"
}

fn sqlight_value_to_driver_helper() -> String {
  "fn value_to_sqlight(value: runtime.Value) -> sqlight.Value {
  case value {
    runtime.SqlNull -> sqlight.null()
    runtime.SqlString(v) -> sqlight.text(v)
    runtime.SqlInt(v) -> sqlight.int(v)
    runtime.SqlFloat(v) -> sqlight.float(v)
    runtime.SqlBool(v) -> sqlight.bool(v)
    runtime.SqlBytes(v) -> sqlight.blob(v)
    runtime.SqlArray(_) -> panic as \"SqlArray is not supported in the SQLite native adapter. Use raw runtime for array parameters, or ensure sqlode.slice() values are expanded before reaching value_to_sqlight.\"
  }
}"
}

fn shork_adapter_config() -> AdapterConfig {
  AdapterConfig(
    library_import: "import shork",
    connection_type: "shork.Connection",
    error_type: "shork.QueryError",
    value_function: type_mapping.scalar_type_to_value_function(model.MySQL, _),
    decoder_function: type_mapping.scalar_type_to_decoder(model.MySQL, _),
    render_params: render_shork_params,
    render_query_call: render_shork_query_call,
    render_one_result: render_shork_one_result,
    render_many_result: render_shork_many_result,
    render_exec_rows_result: render_shork_exec_rows_result,
    render_exec_last_id: render_shork_exec_last_id,
    placeholder_prefix: "?",
    value_to_driver_helper: shork_value_to_driver_helper(),
    // Pull the `affected_rows` field (column 1) out of shork's
    // synthetic INSERT/UPDATE/DELETE row. The exec_rows result path
    // then just projects `returned.rows` without a follow-up SELECT.
    exec_rows_decoder: "{
    use affected <- decode.field(1, decode.int)
    decode.success(affected)
  }",
  )
}

/// Encode a `runtime.Value` into a `shork.Value`. shork's public
/// `Value` type currently exposes constructors for bool / int / float
/// / text / null / calendar but not for bytes — so we add a private
/// `bit_array_to_shork` FFI binding that calls into `shork_ffi.coerce`
/// (the same underlying identity FFI that `shork.text` and friends
/// dispatch through) and pass `BitArray` parameters through unchanged.
/// The Erlang `mysql` library underneath stores them as `BLOB` /
/// `BINARY` byte-for-byte. `SqlArray` still resolves to NULL because
/// MySQL has no first-class array type.
///
/// `SqlBool` is encoded as `shork.int(1 | 0)` rather than
/// `shork.bool(...)`. The Erlang `mysql` library expects integers 1/0
/// on the wire for `TINYINT(1)` / `BOOLEAN` columns; passing the
/// Gleam `True` / `False` atoms verbatim (which is what `shork.bool`
/// does — it is a `coerce` identity FFI) trips `mysql:query/4` with
/// `badarg` during parameter binding.
fn shork_value_to_driver_helper() -> String {
  "@external(erlang, \"shork_ffi\", \"coerce\")
fn bit_array_to_shork(value: BitArray) -> shork.Value

fn value_to_shork(value: runtime.Value) -> shork.Value {
  case value {
    runtime.SqlNull -> shork.null()
    runtime.SqlString(v) -> shork.text(v)
    runtime.SqlInt(v) -> shork.int(v)
    runtime.SqlFloat(v) -> shork.float(v)
    runtime.SqlBool(True) -> shork.int(1)
    runtime.SqlBool(False) -> shork.int(0)
    runtime.SqlBytes(v) -> bit_array_to_shork(v)
    runtime.SqlArray(_) -> panic as \"SqlArray is not supported in the MySQL native adapter. Use raw runtime for array parameters, or ensure sqlode.slice() values are expanded before reaching value_to_shork.\"
  }
}"
}

// ============================================================
// Shared adapter rendering
// ============================================================

fn render_adapter(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  queries: List(model.AnalyzedQuery),
  table_matches: Dict(String, String),
  config: AdapterConfig,
) -> String {
  let model.SqlBlock(gleam:, ..) = block
  let model.GleamOutput(out:, ..) = gleam
  let module_path = common.out_to_module_path(out)

  let has_results =
    list.any(queries, fn(query) {
      model.is_result_command(query.base.command)
      && !list.is_empty(query.result_columns)
    })

  let has_params = list.any(queries, fn(q) { !list.is_empty(q.params) })

  let has_enums = common.queries_have_enums(queries)

  // `list.fold` / `list.map` are used in every query function that has
  // parameters; sqlight adapters additionally use `list.map` to feed
  // the `with:` argument. Whenever any query carries params, the
  // generated adapter needs the list module.
  let imports =
    list.flatten([
      [
        "// Code generated by sqlode. DO NOT EDIT.",
        "",
        "import gleam/dynamic/decode",
      ],
      case has_params {
        True -> ["import gleam/list"]
        False -> []
      },
      ["import gleam/result"],
      adapter_option_import(queries),
      [config.library_import],
      // Every generated adapter now calls `runtime.expand_slice_placeholders`
      // to substitute the placeholder markers emitted by the query parser,
      // so the import is always required (not only when slices are used).
      ["import " <> common.runtime_import_path(gleam)],
      case has_results || has_enums {
        True -> ["import " <> module_path <> "/models"]
        False -> []
      },
      case list.any(queries, fn(q) { !list.is_empty(q.params) }) {
        True -> ["import " <> module_path <> "/params"]
        False -> []
      },
      ["import " <> module_path <> "/queries"],
    ])

  let ctx =
    RenderContext(
      naming_ctx:,
      config:,
      table_matches:,
      emit_sql_as_comment: gleam.emit_sql_as_comment,
      emit_exact_table_names: gleam.emit_exact_table_names,
      type_mapping: gleam.type_mapping,
    )

  let functions =
    queries
    |> list.map(render_adapter_function(ctx, _))
    |> string.join("\n\n")

  let helper = value_to_driver_helper(config)

  string.join(list.flatten([imports, ["", helper, "", functions]]), "\n")
}

/// Render a single `value_to_pog` / `value_to_sqlight` function per
/// adapter file. Generated query functions fold the `runtime.Value`
/// list returned by `runtime.prepare` through this helper, so param
/// encoding lives in one place instead of being inlined per-param.
fn value_to_driver_helper(config: AdapterConfig) -> String {
  config.value_to_driver_helper
}

fn render_adapter_function(
  ctx: RenderContext,
  query: model.AnalyzedQuery,
) -> String {
  let fn_name = query.base.function_name
  let has_params = !list.is_empty(query.params)

  let comment = case ctx.emit_sql_as_comment {
    True -> "// SQL: " <> query.base.sql <> "\n"
    False -> ""
  }

  comment
  <> case query.base.command {
    runtime.QueryOne | runtime.QueryBatchOne ->
      render_adapter_one(ctx, query, fn_name, has_params)
    runtime.QueryMany | runtime.QueryBatchMany ->
      render_adapter_many(ctx, query, fn_name, has_params)
    runtime.QueryExec | runtime.QueryBatchExec | runtime.QueryCopyFrom ->
      render_adapter_exec(
        ctx.naming_ctx,
        query,
        fn_name,
        has_params,
        ctx.config,
      )
    runtime.QueryExecResult ->
      render_adapter_exec(
        ctx.naming_ctx,
        query,
        fn_name,
        has_params,
        ctx.config,
      )
    runtime.QueryExecRows ->
      render_adapter_exec_rows(
        ctx.naming_ctx,
        query,
        fn_name,
        has_params,
        ctx.config,
      )
    runtime.QueryExecLastId ->
      render_adapter_exec_last_id(
        ctx.naming_ctx,
        query,
        fn_name,
        has_params,
        ctx.config,
      )
  }
}

fn render_params_arg(
  naming_ctx: naming.NamingContext,
  query: model.AnalyzedQuery,
  has_params: Bool,
) -> String {
  case has_params {
    True ->
      ", p: params."
      <> naming.to_pascal_case(naming_ctx, query.base.name)
      <> "Params"
    False -> ""
  }
}

fn render_decoder(
  ctx: RenderContext,
  query: model.AnalyzedQuery,
  type_name: String,
) -> String {
  case query.result_columns {
    [] -> "decode.success(Nil)"
    columns -> {
      let #(_, field_lines) =
        list.fold(columns, #(0, []), fn(acc, col) {
          let #(idx, lines) = acc
          case col {
            model.ScalarResult(model.ResultColumn(
              name:,
              scalar_type:,
              nullable:,
              ..,
            )) -> {
              let line =
                render_field_decode_line(
                  naming.to_snake_case(ctx.naming_ctx, name),
                  idx,
                  scalar_type,
                  nullable,
                  ctx.config,
                  ctx.type_mapping,
                )
              #(idx + 1, list.append(lines, [line]))
            }
            model.EmbeddedResult(model.EmbeddedColumn(
              name: embed_name,
              table_name:,
              columns: embed_cols,
            )) -> {
              let #(new_idx, embed_lines) =
                render_embedded_column_lines(
                  ctx,
                  embed_name,
                  table_name,
                  embed_cols,
                  idx,
                )
              #(new_idx, list.append(lines, embed_lines))
            }
          }
        })

      let constructor_fields =
        columns
        |> list.map(fn(col) {
          case col {
            model.ScalarResult(model.ResultColumn(name:, ..)) ->
              naming.to_snake_case(ctx.naming_ctx, name) <> ":"
            model.EmbeddedResult(model.EmbeddedColumn(name:, ..)) ->
              naming.to_snake_case(ctx.naming_ctx, name) <> ":"
          }
        })
        |> string.join(", ")

      builder.concat([
        builder.line("{"),
        builder.lines(field_lines),
        builder.line(
          "    decode.success(models."
          <> type_name
          <> "("
          <> constructor_fields
          <> "))",
        ),
        builder.line("  }"),
      ])
      |> builder.render
    }
  }
}

fn render_base_decoder(
  scalar_type: model.ScalarType,
  config: AdapterConfig,
  type_mapping: model.TypeMapping,
) -> String {
  case scalar_type {
    model.EnumType(_) | model.SetType(_) ->
      common.render_enum_or_set_decoder(scalar_type, config.decoder_function)
    _ ->
      case
        type_mapping == model.StrongMapping
        && type_mapping.is_rich_type(scalar_type)
      {
        True -> {
          let constructor =
            type_mapping.scalar_type_to_gleam_type(
              scalar_type,
              model.StrongMapping,
            )
          "decode.map("
          <> config.decoder_function(scalar_type)
          <> ", models."
          <> constructor
          <> ")"
        }
        False -> config.decoder_function(scalar_type)
      }
  }
}

fn wrap_nullable_decoder(base_decoder: String, nullable: Bool) -> String {
  case nullable {
    True -> "decode.optional(" <> base_decoder <> ")"
    False -> base_decoder
  }
}

fn render_field_decode_line(
  field_name: String,
  idx: Int,
  scalar_type: model.ScalarType,
  nullable: Bool,
  config: AdapterConfig,
  type_mapping: model.TypeMapping,
) -> String {
  let full_decoder =
    render_base_decoder(scalar_type, config, type_mapping)
    |> wrap_nullable_decoder(nullable)
  "    use "
  <> field_name
  <> " <- decode.field("
  <> int.to_string(idx)
  <> ", "
  <> full_decoder
  <> ")"
}

fn render_embedded_column_lines(
  ctx: RenderContext,
  embed_name: String,
  table_name: String,
  embed_cols: List(model.Column),
  start_idx: Int,
) -> #(Int, List(String)) {
  let embed_field_name = naming.to_snake_case(ctx.naming_ctx, embed_name)
  let embed_type_name =
    naming.table_type_name(
      ctx.naming_ctx,
      table_name,
      ctx.emit_exact_table_names,
    )
  let embed_lines =
    list.index_map(embed_cols, fn(embed_col, embed_idx) {
      let full_decoder =
        render_base_decoder(embed_col.scalar_type, ctx.config, ctx.type_mapping)
        |> wrap_nullable_decoder(embed_col.nullable)
      "    use "
      <> naming.to_snake_case(ctx.naming_ctx, embed_col.name)
      <> " <- decode.field("
      <> int.to_string(start_idx + embed_idx)
      <> ", "
      <> full_decoder
      <> ")"
    })
  let embed_constructor_fields =
    list.map(embed_cols, fn(c) {
      naming.to_snake_case(ctx.naming_ctx, c.name) <> ":"
    })
    |> string.join(", ")
  let constructor_line =
    "    let "
    <> embed_field_name
    <> " = models."
    <> embed_type_name
    <> "("
    <> embed_constructor_fields
    <> ")"
  let all_lines = list.append(embed_lines, [constructor_line])
  #(start_idx + list.length(embed_cols), all_lines)
}

fn render_adapter_one(
  ctx: RenderContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
) -> String {
  render_adapter_query_result(
    ctx,
    query,
    fn_name,
    has_params,
    "Option",
    ctx.config.render_one_result,
  )
}

fn render_adapter_many(
  ctx: RenderContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
) -> String {
  render_adapter_query_result(
    ctx,
    query,
    fn_name,
    has_params,
    "List",
    ctx.config.render_many_result,
  )
}

fn render_adapter_query_result(
  ctx: RenderContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
  return_type_wrapper: String,
  render_result: fn() -> List(String),
) -> String {
  let type_name =
    naming.to_pascal_case(ctx.naming_ctx, query.base.name) <> "Row"
  let constructor_name = case
    dict.get(ctx.table_matches, query.base.function_name)
  {
    Ok(table_type) -> table_type
    Error(_) -> type_name
  }
  let params_arg = render_params_arg(ctx.naming_ctx, query, has_params)
  let params_str = ctx.config.render_params(query.params, "p")
  let decoder = render_decoder(ctx, query, constructor_name)
  let return_type = return_type_wrapper <> "(models." <> type_name <> ")"

  builder.concat([
    builder.line(query_fn_signature(
      fn_name,
      ctx.config.connection_type,
      params_arg,
      return_type,
      ctx.config.error_type,
    )),
    builder.line("  let q = queries." <> fn_name <> "()"),
    builder.lines(ctx.config.render_query_call(
      fn_name,
      params_str,
      decoder,
      "q.sql",
      query.params,
    )),
    builder.lines(render_result()),
    builder.line("}"),
  ])
  |> builder.render
}

/// Render the `pub fn name(db: Conn, p: Params) -> Result(R, E) {` line
/// shared by every adapter query function. Keeping the signature in a
/// dedicated helper keeps the callers free of deep `<>` chains.
fn query_fn_signature(
  fn_name: String,
  connection_type: String,
  params_arg: String,
  return_type: String,
  error_type: String,
) -> String {
  "pub fn "
  <> fn_name
  <> "(db: "
  <> connection_type
  <> params_arg
  <> ") -> Result("
  <> return_type
  <> ", "
  <> error_type
  <> ") {"
}

fn render_adapter_exec(
  naming_ctx: naming.NamingContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
  config: AdapterConfig,
) -> String {
  let params_arg = render_params_arg(naming_ctx, query, has_params)
  let params_str = config.render_params(query.params, "p")

  builder.concat([
    builder.line(query_fn_signature(
      fn_name,
      config.connection_type,
      params_arg,
      "Nil",
      config.error_type,
    )),
    builder.line("  let q = queries." <> fn_name <> "()"),
    builder.lines(config.render_query_call(
      fn_name,
      params_str,
      "decode.success(Nil)",
      "q.sql",
      query.params,
    )),
    builder.line("  |> result.map(fn(_) { Nil })"),
    builder.line("}"),
  ])
  |> builder.render
}

fn render_adapter_exec_rows(
  naming_ctx: naming.NamingContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
  config: AdapterConfig,
) -> String {
  let params_arg = render_params_arg(naming_ctx, query, has_params)
  let params_str = config.render_params(query.params, "p")

  builder.concat([
    builder.line(query_fn_signature(
      fn_name,
      config.connection_type,
      params_arg,
      "Int",
      config.error_type,
    )),
    builder.line("  let q = queries." <> fn_name <> "()"),
    builder.lines(config.render_query_call(
      fn_name,
      params_str,
      config.exec_rows_decoder,
      "q.sql",
      query.params,
    )),
    builder.lines(config.render_exec_rows_result()),
    builder.line("}"),
  ])
  |> builder.render
}

fn render_adapter_exec_last_id(
  naming_ctx: naming.NamingContext,
  query: model.AnalyzedQuery,
  fn_name: String,
  has_params: Bool,
  config: AdapterConfig,
) -> String {
  let params_arg = render_params_arg(naming_ctx, query, has_params)
  let params_str = config.render_params(query.params, "p")

  builder.concat([
    builder.line(query_fn_signature(
      fn_name,
      config.connection_type,
      params_arg,
      "Int",
      config.error_type,
    )),
    builder.line("  let q = queries." <> fn_name <> "()"),
    builder.lines(config.render_exec_last_id(
      fn_name,
      params_str,
      "q.sql",
      query.params,
    )),
    builder.line("}"),
  ])
  |> builder.render
}

// ============================================================
// pog-specific rendering
// ============================================================

fn render_pog_query_call(
  _fn_name: String,
  _params_str: String,
  decoder: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  list.flatten([
    render_prepare_lines("pog", "value_to_pog", params),
    ["  |> pog.returning(" <> decoder <> ")", "  |> pog.execute(db)"],
  ])
}

/// No longer generates per-param `pog.parameter(...)` lines. Every
/// generated query now reuses `runtime.prepare(q, p)` and folds the
/// returned values through `value_to_pog`, so the param-string is
/// redundant. Kept for the `AdapterConfig.render_params` field so the
/// wider shape of the config record does not shift in this change.
fn render_pog_params(_params: List(model.QueryParam), _prefix: String) -> String {
  ""
}

/// Shared prepare-and-fold block used by every pog/sqlight query
/// function. Emits one of two shapes depending on whether the query
/// takes parameters: when it does, unpack `runtime.prepare(q, p)` and
/// fold the returned values into `<driver>.query(sql)` through
/// `value_to_<driver>`. When it does not, call `prepare(q, Nil)` and
/// skip the fold entirely.
fn render_prepare_lines(
  driver: String,
  value_to_driver: String,
  params: List(model.QueryParam),
) -> List(String) {
  case list.is_empty(params) {
    True -> [
      "  let #(sql, _values) = runtime.prepare(q, Nil)",
      "  " <> driver <> ".query(sql)",
    ]
    False -> [
      "  let #(sql, values) = runtime.prepare(q, p)",
      "  let query = " <> driver <> ".query(sql)",
      "  let query = list.fold(values, query, fn(acc, v) { "
        <> driver
        <> ".parameter(acc, "
        <> value_to_driver
        <> "(v)) })",
      "  query",
    ]
  }
}

fn render_pog_one_result() -> List(String) {
  render_one_result_with("returned", "returned.rows")
}

fn render_pog_many_result() -> List(String) {
  ["  |> result.map(fn(returned) { returned.rows })"]
}

fn render_pog_exec_rows_result() -> List(String) {
  ["  |> result.map(fn(returned) { returned.count })"]
}

fn render_pog_exec_last_id(
  _fn_name: String,
  _params_str: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  // pog rows decode as positional arrays by default. Decoding
  // `decode.int` directly at the row level tries to interpret the
  // whole row as an integer and fails with UnexpectedResultType; we
  // decode the first column instead.
  let result_lines = [
    "  |> pog.returning({",
    "    use id <- decode.field(0, decode.int)",
    "    decode.success(id)",
    "  })",
    "  |> pog.execute(db)",
    ..render_first_or_default("returned", "returned.rows", "0")
  ]
  list.flatten([
    render_prepare_lines("pog", "value_to_pog", params),
    result_lines,
  ])
}

// ============================================================
// sqlight-specific rendering
// ============================================================

fn render_sqlight_query_call(
  _fn_name: String,
  _params_str: String,
  decoder: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  let prepare_line = case list.is_empty(params) {
    True -> "  let #(sql, values) = runtime.prepare(q, Nil)"
    False -> "  let #(sql, values) = runtime.prepare(q, p)"
  }
  [
    prepare_line,
    "  sqlight.query(",
    "    sql,",
    "    on: db,",
    "    with: list.map(values, value_to_sqlight),",
    "    expecting: " <> decoder <> ",",
    "  )",
  ]
}

/// Unused under the prepare-and-fold adapter shape; see
/// `render_pog_params` for the rationale.
fn render_sqlight_params(
  _params: List(model.QueryParam),
  _prefix: String,
) -> String {
  ""
}

fn render_sqlight_one_result() -> List(String) {
  render_one_result_with("rows", "rows")
}

fn render_sqlight_many_result() -> List(String) {
  []
}

fn render_sqlight_exec_rows_result() -> List(String) {
  list.flatten([
    [
      "  |> result.try(fn(_) {",
      "    sqlight.query(",
      "      \"SELECT changes()\",",
      "      on: db,",
      "      with: [],",
      "      expecting: decode.at([0], decode.int),",
      "    )",
      "  })",
    ],
    render_first_or_default("rows", "rows", "0"),
  ])
}

fn render_sqlight_exec_last_id(
  _fn_name: String,
  _params_str: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  let prepare_line = case list.is_empty(params) {
    True -> "  let #(sql, values) = runtime.prepare(q, Nil)"
    False -> "  let #(sql, values) = runtime.prepare(q, p)"
  }
  list.flatten([
    [
      prepare_line,
      "  sqlight.query(",
      "    sql,",
      "    on: db,",
      "    with: list.map(values, value_to_sqlight),",
      "    expecting: decode.success(Nil),",
      "  )",
      "  |> result.try(fn(_) {",
      "    sqlight.query(",
      "      \"SELECT last_insert_rowid()\",",
      "      on: db,",
      "      with: [],",
      "      expecting: decode.at([0], decode.int),",
      "    )",
      "  })",
    ],
    render_first_or_default("rows", "rows", "0"),
  ])
}

// ============================================================
// shork-specific rendering
// ============================================================
//
// shork's `shork.execute` always returns `Returned(t)` regardless of
// the statement shape. For SELECT queries `Returned.rows` holds the
// decoded result rows; for INSERT / UPDATE / DELETE it holds exactly
// one synthetic row with the columns
// `[last_insert_id, affected_rows, warning_count]`, which is why the
// :execrows / :execlastid paths decode field 0 or 1 of that synthetic
// row instead of issuing a follow-up `SELECT ROW_COUNT()` /
// `SELECT LAST_INSERT_ID()`.

fn render_shork_query_call(
  _fn_name: String,
  _params_str: String,
  decoder: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  list.flatten([
    render_prepare_lines("shork", "value_to_shork", params),
    ["  |> shork.returning(" <> decoder <> ")", "  |> shork.execute(db)"],
  ])
}

/// Unused under the prepare-and-fold adapter shape; kept so the
/// AdapterConfig record shape stays uniform across drivers.
fn render_shork_params(
  _params: List(model.QueryParam),
  _prefix: String,
) -> String {
  ""
}

fn render_shork_one_result() -> List(String) {
  render_one_result_with("returned", "returned.rows")
}

fn render_shork_many_result() -> List(String) {
  ["  |> result.map(fn(returned) { returned.rows })"]
}

/// `:execrows` — shork's synthetic INSERT/UPDATE/DELETE row has
/// `affected_rows` in column index 1.
fn render_shork_exec_rows_result() -> List(String) {
  [
    "  |> result.map(fn(returned) {",
    "    case returned.rows {",
    "      [rows, ..] -> rows",
    "      [] -> 0",
    "    }",
    "  })",
  ]
}

/// `:execlastid` — shork's synthetic INSERT row has
/// `last_insert_id` in column index 0. No follow-up SELECT needed.
fn render_shork_exec_last_id(
  _fn_name: String,
  _params_str: String,
  _sql_expr: String,
  params: List(model.QueryParam),
) -> List(String) {
  list.flatten([
    render_prepare_lines("shork", "value_to_shork", params),
    [
      "  |> shork.returning({",
      "    use id <- decode.field(0, decode.int)",
      "    decode.success(id)",
      "  })",
      "  |> shork.execute(db)",
    ],
    render_first_or_default("returned", "returned.rows", "0"),
  ])
}

// ============================================================
// Shared helpers
// ============================================================

fn render_one_result_with(param: String, rows_expr: String) -> List(String) {
  [
    "  |> result.map(fn(" <> param <> ") {",
    "    case " <> rows_expr <> " {",
    "      [row, ..] -> Some(row)",
    "      [] -> None",
    "    }",
    "  })",
  ]
}

fn render_first_or_default(
  param: String,
  rows_expr: String,
  default: String,
) -> List(String) {
  [
    "  |> result.map(fn(" <> param <> ") {",
    "    case " <> rows_expr <> " {",
    "      [id, ..] -> id",
    "      [] -> " <> default,
    "    }",
    "  })",
  ]
}

/// Emit a `gleam/option` import line tailored to what the generated
/// adapter actually references. The `Option` type is needed
/// whenever any param / result column is nullable or whenever any
/// query is `QueryOne` / `QueryBatchOne` (the wrapper returns
/// `Option(Row)`); the `None` / `Some` constructors are only
/// referenced by the `QueryOne` / `QueryBatchOne` row-list match
/// (`[row, ..] -> Some(row)` / `[] -> None`). Pulling unused
/// constructors into the import trips `gleam build`'s unused-import
/// warnings under `warnings_as_errors`, which downstream users
/// cannot fix because the file is `// DO NOT EDIT`. (#463)
fn adapter_option_import(queries: List(model.AnalyzedQuery)) -> List(String) {
  let needs_type = adapter_needs_option_type(queries)
  let needs_constructors = adapter_needs_option_constructors(queries)
  case needs_type, needs_constructors {
    False, False -> []
    True, True -> ["import gleam/option.{type Option, None, Some}"]
    True, False -> ["import gleam/option.{type Option}"]
    // Unreachable today: `adapter_needs_option_type` short-circuits
    // to True whenever `adapter_query_uses_option_constructors`
    // does. Kept as a defensive guard so a future refactor that
    // decouples the two predicates still emits a buildable import.
    False, True -> ["import gleam/option.{None, Some}"]
  }
}

fn adapter_needs_option_type(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, fn(query) {
    let has_nullable_params =
      list.any(query.params, fn(param) { param.nullable })
    let has_nullable_results =
      list.any(query.result_columns, fn(col) {
        case col {
          model.ScalarResult(model.ResultColumn(nullable: True, ..)) -> True
          model.ScalarResult(..) -> False
          model.EmbeddedResult(model.EmbeddedColumn(columns:, ..)) ->
            list.any(columns, fn(c) { c.nullable })
        }
      })
    has_nullable_params
    || has_nullable_results
    || adapter_query_uses_option_constructors(query)
  })
}

fn adapter_needs_option_constructors(queries: List(model.AnalyzedQuery)) -> Bool {
  list.any(queries, adapter_query_uses_option_constructors)
}

fn adapter_query_uses_option_constructors(query: model.AnalyzedQuery) -> Bool {
  query.base.command == runtime.QueryOne
  || query.base.command == runtime.QueryBatchOne
}
