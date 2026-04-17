import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
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
    model.MySQL -> render_mysql_adapter()
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
    runtime.SqlArray(_) -> sqlight.null()
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
      case needs_option_import_for_adapter(queries) {
        True -> ["import gleam/option.{type Option, None, Some}"]
        False -> []
      },
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

      "{\n"
      <> string.join(field_lines, "\n")
      <> "\n    decode.success(models."
      <> type_name
      <> "("
      <> constructor_fields
      <> "))\n  }"
    }
  }
}

fn render_base_decoder(
  scalar_type: model.ScalarType,
  config: AdapterConfig,
  type_mapping: model.TypeMapping,
) -> String {
  case scalar_type {
    model.EnumType(enum_name) ->
      "decode.then(decode.string, fn(s) { case models."
      <> type_mapping.enum_from_string_fn(enum_name)
      <> "(s) { Ok(v) -> decode.success(v) Error(_) -> decode.failure(s, \"valid "
      <> enum_name
      <> " value\") } })"
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

  string.join(
    list.flatten([
      [
        "pub fn "
          <> fn_name
          <> "(db: "
          <> ctx.config.connection_type
          <> params_arg
          <> ") -> Result("
          <> return_type_wrapper
          <> "(models."
          <> type_name
          <> "), "
          <> ctx.config.error_type
          <> ") {",
        "  let q = queries." <> fn_name <> "()",
      ],
      ctx.config.render_query_call(
        fn_name,
        params_str,
        decoder,
        "q.sql",
        query.params,
      ),
      render_result(),
      ["}"],
    ]),
    "\n",
  )
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

  string.join(
    list.flatten([
      [
        "pub fn "
          <> fn_name
          <> "(db: "
          <> config.connection_type
          <> params_arg
          <> ") -> Result(Nil, "
          <> config.error_type
          <> ") {",
        "  let q = queries." <> fn_name <> "()",
      ],
      config.render_query_call(
        fn_name,
        params_str,
        "decode.success(Nil)",
        "q.sql",
        query.params,
      ),
      [
        "  |> result.map(fn(_) { Nil })",
        "}",
      ],
    ]),
    "\n",
  )
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

  string.join(
    list.flatten([
      [
        "pub fn "
          <> fn_name
          <> "(db: "
          <> config.connection_type
          <> params_arg
          <> ") -> Result(Int, "
          <> config.error_type
          <> ") {",
        "  let q = queries." <> fn_name <> "()",
      ],
      config.render_query_call(
        fn_name,
        params_str,
        "decode.success(Nil)",
        "q.sql",
        query.params,
      ),
      config.render_exec_rows_result(),
      ["}"],
    ]),
    "\n",
  )
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

  string.join(
    list.flatten([
      [
        "pub fn "
          <> fn_name
          <> "(db: "
          <> config.connection_type
          <> params_arg
          <> ") -> Result(Int, "
          <> config.error_type
          <> ") {",
        "  let q = queries." <> fn_name <> "()",
      ],
      config.render_exec_last_id(fn_name, params_str, "q.sql", query.params),
      ["}"],
    ]),
    "\n",
  )
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
// MySQL stub
// ============================================================

fn render_mysql_adapter() -> String {
  string.join(
    [
      "// Code generated by sqlode. DO NOT EDIT.",
      "// MySQL adapter generation is not yet available.",
      "// No Gleam MySQL driver package is currently supported.",
      "// Use runtime: \"raw\" and handle database interaction manually.",
    ],
    "\n",
  )
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

fn needs_option_import_for_adapter(queries: List(model.AnalyzedQuery)) -> Bool {
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
    let has_one_command =
      query.base.command == runtime.QueryOne
      || query.base.command == runtime.QueryBatchOne

    has_nullable_params || has_nullable_results || has_one_command
  })
}
