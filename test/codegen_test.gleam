import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/internal/codegen/adapter
import sqlode/internal/codegen/common
import sqlode/internal/codegen/models
import sqlode/internal/codegen/params
import sqlode/internal/codegen/queries
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_parser
import sqlode/internal/schema_parser
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

pub fn render_queries_module_test() {
  let naming_ctx = naming.new()
  let block = test_block()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered = queries.render(naming_ctx, block, analyzed, dict.new(), False)

  string.contains(
    rendered,
    "pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) {",
  )
  |> should.be_true()
  string.contains(rendered, "import sqlode/runtime")
  |> should.be_true()
  string.contains(rendered, "import db/params")
  |> should.be_true()
  string.contains(rendered, "command: runtime.QueryOne")
  |> should.be_true()
  string.contains(rendered, "placeholder_style: runtime.DollarNumbered,")
  |> should.be_true()
  string.contains(rendered, "encode: params.get_author_values,")
  |> should.be_true()
  string.contains(rendered, "slice_info: fn(_) { [] },")
  |> should.be_true()
  string.contains(rendered, "pub fn all() -> List(runtime.QueryInfo) {")
  |> should.be_true()
  list.length(analyzed) |> should.equal(2)
  // Parameterless query should use Nil type and inline encode
  string.contains(rendered, "pub fn list_authors() -> runtime.RawQuery(Nil) {")
  |> should.be_true()
  string.contains(rendered, "encode: fn(_) { [] },")
  |> should.be_true()
}

pub fn render_prepare_helpers_test() {
  // Function-first wrapper (Issue #394): the generated module should
  // expose `prepare_<function_name>(...)` helpers that construct the
  // params record inline and return the `(sql, values)` pair, so the
  // common call site is a single function call instead of descriptor
  // + params constructor + runtime.prepare composition.
  let naming_ctx = naming.new()
  let block = test_block()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered = queries.render(naming_ctx, block, analyzed, dict.new(), False)

  // Parameterised query — arg list mirrors the params record fields.
  string.contains(
    rendered,
    "pub fn prepare_get_author(id: Int) -> #(String, List(runtime.Value)) {",
  )
  |> should.be_true()
  string.contains(rendered, "runtime.prepare(")
  |> should.be_true()
  string.contains(rendered, "params.GetAuthorParams(id: id),")
  |> should.be_true()

  // Parameterless query — no arguments, passes Nil to runtime.prepare.
  string.contains(
    rendered,
    "pub fn prepare_list_authors() -> #(String, List(runtime.Value)) {",
  )
  |> should.be_true()
  string.contains(rendered, "runtime.prepare(list_authors(), Nil)")
  |> should.be_true()
}

pub fn render_params_module_test() {
  let naming_ctx = naming.new()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  string.contains(rendered, "pub type GetAuthorParams {")
  |> should.be_true()
  string.contains(rendered, "GetAuthorParams(id: Int)")
  |> should.be_true()
  string.contains(rendered, "runtime.int(params.id)")
  |> should.be_true()
  // Parameterless queries should NOT generate Params type
  string.contains(rendered, "pub type ListAuthorsParams {")
  |> should.be_false()
  string.contains(rendered, "list_authors_values")
  |> should.be_false()
}

pub fn render_params_module_imports_only_option_type_test() {
  // params.gleam never uses None / Some in its rendered code, so the
  // `gleam/option` import must be type-only. A wider import trips
  // `gleam build`'s unused-import warnings under
  // `warnings_as_errors`, which downstream users cannot fix because
  // the file is `// DO NOT EDIT`. Regression test for #463.
  let naming_ctx = naming.new()
  let analyzed = analyzed_queries("test/fixtures/macro_edge_cases.sql")
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  string.contains(rendered, "import gleam/option.{type Option}")
  |> should.be_true()
  // Negative form: must not pull in the constructors. Asserting
  // against the import shapes directly (rather than the bare
  // `None` / `Some` substrings) keeps this robust against future
  // fixtures whose rendered output legitimately contains those
  // names in unrelated contexts (column names, docstrings, etc.).
  string.contains(rendered, "import gleam/option.{type Option, None, Some}")
  |> should.be_false()
  string.contains(rendered, "import gleam/option.{None, Some}")
  |> should.be_false()
}

pub fn render_models_module_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  string.contains(rendered, "// Code generated by sqlode. DO NOT EDIT.")
  |> should.be_true()
  // Table type should be emitted
  string.contains(rendered, "pub type Author {")
  |> should.be_true()
  // Query row types (partial match — only id, name from 3-column table)
  string.contains(rendered, "pub type GetAuthorRow {")
  |> should.be_true()
  string.contains(rendered, "GetAuthorRow(id: Int, name: String)")
  |> should.be_true()
  string.contains(rendered, "pub type ListAuthorsRow {")
  |> should.be_true()
  string.contains(rendered, "ListAuthorsRow(id: Int, name: String)")
  |> should.be_true()
}

pub fn render_models_module_with_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let analyzed = analyzed_star_queries()
  let table_matches = dict.from_list([#("get_all_authors", "Author")])
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      table_matches,
      model.StringMapping,
      False,
    )

  string.contains(rendered, "import gleam/option.{type Option}")
  |> should.be_true()
  string.contains(rendered, "bio: Option(String)")
  |> should.be_true()
  // SELECT * matches table exactly, should emit alias
  string.contains(rendered, "pub type GetAllAuthorsRow =")
  |> should.be_true()
}

pub fn render_models_module_no_exec_rows_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let analyzed = analyzed_queries("test/fixtures/create_query.sql")
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  // No Row types for exec queries, but table type should still be present
  string.contains(rendered, "pub type Author {")
  |> should.be_true()
}

pub fn render_pog_adapter_test() {
  let naming_ctx = naming.new()
  let block = test_block_native()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  string.contains(rendered, "import pog") |> should.be_true()
  string.contains(rendered, "import db/models") |> should.be_true()
  string.contains(rendered, "import db/params") |> should.be_true()
  string.contains(rendered, "import db/queries") |> should.be_true()
  string.contains(rendered, "pub fn get_author(db: pog.Connection")
  |> should.be_true()
  string.contains(
    rendered,
    "fn value_to_pog(value: runtime.Value) -> pog.Value",
  )
  |> should.be_true()
  string.contains(rendered, "runtime.prepare(q, p)") |> should.be_true()
  string.contains(rendered, "pog.query(sql)") |> should.be_true()
  string.contains(
    rendered,
    "list.fold(values, query, fn(acc, v) { pog.parameter(acc, value_to_pog(v)) })",
  )
  |> should.be_true()
  string.contains(rendered, "decode.success(models.GetAuthorRow(")
  |> should.be_true()
  string.contains(rendered, "pub fn list_authors(db: pog.Connection)")
  |> should.be_true()
}

pub fn render_sqlight_adapter_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.SQLite,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )

  let assert Ok(schema_content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", schema_content)])
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.SQLite,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  string.contains(rendered, "import sqlight") |> should.be_true()
  string.contains(rendered, "pub fn get_author(db: sqlight.Connection")
  |> should.be_true()
  string.contains(rendered, "sqlight.query(") |> should.be_true()
  string.contains(rendered, "decode.success(models.GetAuthorRow(")
  |> should.be_true()
}

/// Issue #492: a `:one` query whose only column comes from a SQLite
/// scalar function (`last_insert_rowid()`) used to leave the type
/// inference unable to resolve the column, so `models.gleam` did not
/// gain a row type and the sqlight adapter referenced a non-existent
/// type while collapsing the decoder to `decode.success(Nil)`.
pub fn render_sqlight_adapter_one_function_column_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.SQLite,
      schema: ["schema.sql"],
      queries: ["query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )

  // No tables are needed; the column source is a scalar function.
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("schema.sql", "")])

  let query_sql =
    "-- name: GetLastInsertId :one\nSELECT last_insert_rowid() AS id;\n"
  let assert Ok(queries) =
    query_parser.parse_file("query.sql", model.SQLite, naming_ctx, query_sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // The adapter must reference the row type ...
  string.contains(rendered, "models.GetLastInsertIdRow") |> should.be_true()
  // ... read the column with a real int decoder ...
  string.contains(rendered, "decode.int") |> should.be_true()
  // ... and not silently collapse to a Nil-shaped decoder.
  string.contains(rendered, "decode.success(Nil)") |> should.be_false()

  // The matching row type must also be emitted in `models.gleam` so the
  // adapter's reference resolves at compile time.
  let models_rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )
  string.contains(models_rendered, "pub type GetLastInsertIdRow")
  |> should.be_true()
  string.contains(models_rendered, "id: Int")
  |> should.be_true()
}

/// Issue #491: SQLite engine should accept `LIMIT sqlode.arg(lim)` and
/// `OFFSET sqlode.arg(off)` without an explicit cast. Both placeholders
/// are bound to `IntType` by the LIMIT/OFFSET integer-context rule.
pub fn analyze_sqlite_limit_offset_params_pin_int_type_test() {
  let naming_ctx = naming.new()
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("schema.sql", "CREATE TABLE pages (id INTEGER, slug TEXT);"),
    ])
  let query_sql =
    "-- name: ListPages :many\nSELECT slug FROM pages ORDER BY id DESC LIMIT sqlode.arg(lim) OFFSET sqlode.arg(off);\n"
  let assert Ok(queries) =
    query_parser.parse_file("query.sql", model.SQLite, naming_ctx, query_sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert [analyzed_query] = analyzed
  // Both placeholders surface as QueryParam entries with IntType.
  list.length(analyzed_query.params) |> should.equal(2)
  list.all(analyzed_query.params, fn(p) { p.scalar_type == model.IntType })
  |> should.be_true()
  // Param names come from the macro labels, not from the column they
  // bind against (there is no column to bind to in LIMIT/OFFSET).
  list.map(analyzed_query.params, fn(p) { p.field_name })
  |> list.contains("lim")
  |> should.be_true()
  list.map(analyzed_query.params, fn(p) { p.field_name })
  |> list.contains("off")
  |> should.be_true()
}

/// Issue #491: an explicit CAST is still honoured. `LIMIT
/// CAST(sqlode.arg(lim) AS INTEGER)` resolves to `IntType` through the
/// LIMIT-context rule (and would also resolve through the
/// `extract_type_casts` path for engines that support cast suffix).
pub fn analyze_sqlite_limit_offset_with_cast_still_works_test() {
  let naming_ctx = naming.new()
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("schema.sql", "CREATE TABLE pages (id INTEGER, slug TEXT);"),
    ])
  let query_sql =
    "-- name: ListPages :many\nSELECT slug FROM pages LIMIT CAST(sqlode.arg(lim) AS INTEGER) OFFSET CAST(sqlode.arg(off) AS INTEGER);\n"
  let assert Ok(queries) =
    query_parser.parse_file("query.sql", model.SQLite, naming_ctx, query_sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let assert [analyzed_query] = analyzed
  list.length(analyzed_query.params) |> should.equal(2)
  list.all(analyzed_query.params, fn(p) { p.scalar_type == model.IntType })
  |> should.be_true()
}

pub fn render_params_module_slice_test() {
  let naming_ctx = naming.new()
  let analyzed = analyzed_slice_queries(model.PostgreSQL)
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  // The type should use List(...) for slice params
  string.contains(rendered, "ids: List(")
  |> should.be_true()
  // Should use list.flatten for values function
  string.contains(rendered, "list.flatten(")
  |> should.be_true()
  string.contains(rendered, "list.map(params.ids, runtime.")
  |> should.be_true()
  // Should import gleam/list
  string.contains(rendered, "import gleam/list")
  |> should.be_true()
}

pub fn render_pog_adapter_imports_option_constructors_with_query_one_test() {
  // The fixture's GetAuthor query is `:one`, whose generated wrapper
  // calls `Some(row)` / `None`. The adapter must therefore import
  // both the type and the constructors. Regression test for #463.
  let naming_ctx = naming.new()
  let block = test_block_native()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  string.contains(rendered, "import gleam/option.{type Option, None, Some}")
  |> should.be_true()
}

pub fn render_pog_adapter_imports_only_option_type_without_query_one_test() {
  // macro_edge_cases.sql has only `:many` and `:exec` queries (no
  // `:one`), but its `narg(...)` params make the generated row /
  // params types reference `Option(...)`. The adapter must import
  // only the type — emitting `None, Some` would trip the
  // `// DO NOT EDIT` file's unused-import warnings under
  // `warnings_as_errors`. Regression test for #463.
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/macro_edge_cases.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let analyzed = analyzed_queries("test/fixtures/macro_edge_cases.sql")
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  string.contains(rendered, "import gleam/option.{type Option}")
  |> should.be_true()
  // Negative form: must not pull in the constructors.
  string.contains(rendered, "import gleam/option.{type Option, None, Some}")
  |> should.be_false()
}

pub fn render_pog_adapter_slice_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/macro_edge_cases.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let analyzed = analyzed_slice_queries(model.PostgreSQL)
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Should import runtime for slice expansion via runtime.prepare
  string.contains(rendered, "import sqlode/runtime")
  |> should.be_true()
  // Should call runtime.prepare(q, p) to unpack sql + values
  string.contains(rendered, "runtime.prepare(q, p)") |> should.be_true()
  // Should fold the Value list into pog parameters via value_to_pog
  string.contains(
    rendered,
    "list.fold(values, query, fn(acc, v) { pog.parameter(acc, value_to_pog(v)) })",
  )
  |> should.be_true()
  // Should use let query = style
  string.contains(rendered, "let query = pog.query(sql)")
  |> should.be_true()
}

pub fn render_sqlight_adapter_slice_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.SQLite,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/macro_edge_cases.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let analyzed = analyzed_slice_queries(model.SQLite)
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Should use runtime.prepare to get sql + values in one call
  string.contains(rendered, "runtime.prepare(q, p)") |> should.be_true()
  // Should convert runtime.Value list into sqlight.Value list
  string.contains(rendered, "list.map(values, value_to_sqlight)")
  |> should.be_true()
  // Helper function is emitted once at the top of the file
  string.contains(
    rendered,
    "fn value_to_sqlight(value: runtime.Value) -> sqlight.Value",
  )
  |> should.be_true()
  // SqlArray should panic instead of silently converting to null (#502)
  string.contains(rendered, "SqlArray is not supported in the SQLite native")
  |> should.be_true()
}

pub fn expand_slice_placeholders_single_test() {
  let sql = "SELECT id, name FROM authors WHERE id IN (__sqlode_slice_1__)"
  let result =
    runtime.expand_slice_placeholders(sql, [#(1, 3)], 1, runtime.DollarNumbered)
  result
  |> should.equal("SELECT id, name FROM authors WHERE id IN ($1, $2, $3)")
}

pub fn expand_slice_placeholders_with_renumbering_test() {
  let sql =
    "SELECT * FROM users WHERE name = __sqlode_param_1__ AND id IN (__sqlode_slice_2__) AND status = __sqlode_param_3__"
  let result =
    runtime.expand_slice_placeholders(sql, [#(2, 3)], 3, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT * FROM users WHERE name = $1 AND id IN ($2, $3, $4) AND status = $5",
  )
}

pub fn expand_slice_placeholders_sqlite_test() {
  let sql = "SELECT id, name FROM authors WHERE id IN (__sqlode_slice_1__)"
  let result =
    runtime.expand_slice_placeholders(
      sql,
      [#(1, 2)],
      1,
      runtime.QuestionNumbered,
    )
  result
  |> should.equal("SELECT id, name FROM authors WHERE id IN (?1, ?2)")
}

pub fn expand_slice_placeholders_no_slices_test() {
  let sql = "SELECT * FROM users WHERE id = __sqlode_param_1__"
  let result =
    runtime.expand_slice_placeholders(sql, [], 1, runtime.DollarNumbered)
  result |> should.equal("SELECT * FROM users WHERE id = $1")
}

pub fn expand_slice_placeholders_empty_slice_test() {
  let sql = "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)"
  let result =
    runtime.expand_slice_placeholders(sql, [#(1, 0)], 1, runtime.DollarNumbered)
  result |> should.equal("SELECT * FROM users WHERE id IN (NULL)")
}

pub fn expand_slice_placeholders_empty_slice_with_other_params_test() {
  let sql =
    "SELECT * FROM users WHERE name = __sqlode_param_1__ AND id IN (__sqlode_slice_2__) AND status = __sqlode_param_3__"
  let result =
    runtime.expand_slice_placeholders(sql, [#(2, 0)], 3, runtime.DollarNumbered)
  result
  |> should.equal(
    "SELECT * FROM users WHERE name = $1 AND id IN (NULL) AND status = $2",
  )
}

pub fn expand_slice_placeholders_empty_slice_sqlite_test() {
  let sql = "SELECT * FROM users WHERE id IN (__sqlode_slice_1__)"
  let result =
    runtime.expand_slice_placeholders(
      sql,
      [#(1, 0)],
      1,
      runtime.QuestionNumbered,
    )
  result |> should.equal("SELECT * FROM users WHERE id IN (NULL)")
}

// --- Table type and alias tests ---

pub fn render_models_table_type_alias_for_exact_match_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let analyzed = analyzed_star_queries()
  let table_matches = dict.from_list([#("get_all_authors", "Author")])
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      table_matches,
      model.StringMapping,
      False,
    )

  // Table type should be emitted
  string.contains(rendered, "pub type Author {")
  |> should.be_true()
  string.contains(
    rendered,
    "Author(id: Int, name: String, bio: Option(String))",
  )
  |> should.be_true()
  // Exact match should produce alias, not duplicate record
  string.contains(rendered, "pub type GetAllAuthorsRow =")
  |> should.be_true()
  string.contains(rendered, "GetAllAuthorsRow =\n  Author")
  |> should.be_true()
}

pub fn render_models_partial_match_generates_row_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let analyzed = analyzed_queries("test/fixtures/query.sql")
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  // Partial match (only id, name from 3-column table) should NOT produce alias
  string.contains(rendered, "pub type GetAuthorRow {")
  |> should.be_true()
  string.contains(rendered, "pub type GetAuthorRow =")
  |> should.be_false()
}

pub fn render_adapter_uses_table_constructor_for_match_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let analyzed = analyzed_star_queries()
  let table_matches = dict.from_list([#("get_all_authors", "Author")])
  let rendered = adapter.render(naming_ctx, block, analyzed, table_matches)

  // When matched, decoder should use table constructor
  string.contains(rendered, "decode.success(models.Author(")
  |> should.be_true()
  // Return type should still use the Row alias
  string.contains(rendered, "models.GetAllAuthorsRow")
  |> should.be_true()
}

// --- Test helpers ---

fn analyzed_slice_queries(engine: model.Engine) -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let assert Ok(schema_content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", schema_content)])
  let sql =
    "-- name: GetByIds :many\nSELECT id, name FROM authors WHERE id IN (sqlode.slice(ids));"
  let assert Ok(queries) =
    query_parser.parse_file("slice.sql", engine, naming_ctx, sql)
  let assert Ok(result) =
    query_analyzer.analyze_queries(engine, catalog, naming_ctx, queries)
  result
}

fn test_block() -> model.SqlBlock {
  model.SqlBlock(
    name: None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/schema.sql"],
    queries: ["test/fixtures/query.sql"],
    gleam: model.GleamOutput(
      out: "src/db",
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
      query_parameter_limit: option.None,
    ),
    overrides: model.empty_overrides(),
  )
}

fn test_block_native() -> model.SqlBlock {
  model.SqlBlock(
    name: None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/schema.sql"],
    queries: ["test/fixtures/query.sql"],
    gleam: model.GleamOutput(
      out: "src/db",
      runtime: model.Native,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
      query_parameter_limit: option.None,
    ),
    overrides: model.empty_overrides(),
  )
}

fn test_catalog() -> model.Catalog {
  let assert Ok(schema_content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", schema_content)])
  catalog
}

fn analyzed_queries(path: String) -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(queries) =
    query_parser.parse_file(path, model.PostgreSQL, naming_ctx, content)

  let assert Ok(result) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result
}

// --- Enum type tests ---

pub fn render_enum_from_string_returns_result_test() {
  let naming_ctx = naming.new()
  let catalog = enum_test_catalog()
  let analyzed = enum_analyzed_queries()
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  // from_string should return Result
  string.contains(
    rendered,
    "pub fn status_from_string(value: String) -> Result(Status, String) {",
  )
  |> should.be_true()

  // Valid values should return Ok
  string.contains(rendered, "\"active\" -> Ok(Active)")
  |> should.be_true()
  string.contains(rendered, "\"inactive\" -> Ok(Inactive)")
  |> should.be_true()
  string.contains(rendered, "\"banned\" -> Ok(Banned)")
  |> should.be_true()

  // Unknown values should return Error
  string.contains(rendered, "_ -> Error(\"Unknown status value: \" <> value)")
  |> should.be_true()
}

pub fn render_enum_decoder_uses_decode_then_test() {
  let naming_ctx = naming.new()
  let analyzed = enum_analyzed_queries()

  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/enum_schema.sql"],
      queries: ["test/fixtures/enum_query.sql"],
      gleam: model.GleamOutput(
        out: "src/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Should use decode.then, not decode.map for enums
  string.contains(rendered, "decode.then(decode.string")
  |> should.be_true()
  string.contains(rendered, "status_from_string")
  |> should.be_true()
  string.contains(rendered, "decode.success(v)")
  |> should.be_true()
  // Error branch must pass a typed zero (the generated
  // `<name>_default()` helper), not the raw decoded string, so the
  // case expression type-checks as `Decoder(<EnumType>)` rather than
  // `Decoder(String)`.
  string.contains(rendered, "decode.failure(models.status_default()")
  |> should.be_true()

  // Should NOT use decode.map for enum decoding
  string.contains(
    rendered,
    "decode.map(decode.string, models.status_from_string",
  )
  |> should.be_false()
}

fn enum_test_catalog() -> model.Catalog {
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/enum_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/enum_schema.sql", schema_content),
    ])
  catalog
}

fn enum_analyzed_queries() -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let catalog = enum_test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/enum_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/enum_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(result) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result
}

pub fn render_pog_adapter_enum_slice_converts_to_string_test() {
  let naming_ctx = naming.new()
  let analyzed = enum_analyzed_queries()

  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/enum_schema.sql"],
      queries: ["test/fixtures/enum_query.sql"],
      gleam: model.GleamOutput(
        out: "src/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Under the prepare-and-fold shape, enum conversion happens in the
  // params module's `*_values` function, not in the adapter. The
  // adapter just folds `runtime.Value`s through `value_to_pog`, so the
  // adapter source should contain the helper and the fold, and must
  // not contain per-param enum-to-string conversions (those have
  // already happened upstream in `params.*_values`).
  string.contains(
    rendered,
    "fn value_to_pog(value: runtime.Value) -> pog.Value",
  )
  |> should.be_true()
  string.contains(
    rendered,
    "list.fold(values, query, fn(acc, v) { pog.parameter(acc, value_to_pog(v)) })",
  )
  |> should.be_true()
  string.contains(rendered, "models.status_to_string(v)")
  |> should.be_false()
}

pub fn render_sqlight_adapter_enum_slice_converts_to_string_test() {
  let naming_ctx = naming.new()
  let catalog = enum_test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/enum_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/enum_query.sql",
      model.SQLite,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)

  let block =
    model.SqlBlock(
      name: None,
      engine: model.SQLite,
      schema: ["test/fixtures/enum_schema.sql"],
      queries: ["test/fixtures/enum_query.sql"],
      gleam: model.GleamOutput(
        out: "src/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Same story as the pog side: enum conversion now happens in
  // `params.*_values`, so the adapter has the sqlight helper and
  // the list.map-to-driver step instead of per-param conversions.
  string.contains(
    rendered,
    "fn value_to_sqlight(value: runtime.Value) -> sqlight.Value",
  )
  |> should.be_true()
  string.contains(rendered, "list.map(values, value_to_sqlight)")
  |> should.be_true()
  string.contains(rendered, "models.status_to_string(v)")
  |> should.be_false()
}

// --- README snapshot tests ---
// These tests verify that the README code examples match actual generated output.
// If a test here fails, it means the README examples are stale and need updating.

pub fn readme_params_snapshot_test() {
  let naming_ctx = naming.new()
  let analyzed = readme_analyzed_queries()
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  // README: pub type GetAuthorParams { GetAuthorParams(id: Int) }
  string.contains(rendered, "pub type GetAuthorParams {")
  |> should.be_true()
  string.contains(rendered, "GetAuthorParams(id: Int)")
  |> should.be_true()

  // README: pub fn get_author_values(params: GetAuthorParams) -> List(Value) {
  //           [runtime.int(params.id)]
  string.contains(rendered, "runtime.int(params.id)")
  |> should.be_true()

  // README: pub type CreateAuthorParams { CreateAuthorParams(... bio: Option(String)) }
  string.contains(rendered, "pub type CreateAuthorParams {")
  |> should.be_true()
  string.contains(rendered, "bio: Option(String)")
  |> should.be_true()

  // README sqlode.slice: pub type GetAuthorsByIdsParams { GetAuthorsByIdsParams(ids: List(Int)) }
  string.contains(rendered, "pub type GetAuthorsByIdsParams {")
  |> should.be_true()
  string.contains(rendered, "ids: List(Int)")
  |> should.be_true()
}

pub fn readme_models_snapshot_test() {
  let naming_ctx = naming.new()
  let catalog = readme_test_catalog()
  let analyzed = readme_analyzed_queries()
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  // README: pub type Author { Author(id: Int, name: String, bio: Option(String)) }
  string.contains(rendered, "pub type Author {")
  |> should.be_true()
  string.contains(
    rendered,
    "Author(id: Int, name: String, bio: Option(String))",
  )
  |> should.be_true()

  // README: partial match produces separate row type
  string.contains(rendered, "pub type GetAuthorRow {")
  |> should.be_true()
  string.contains(rendered, "GetAuthorRow(id: Int, name: String)")
  |> should.be_true()

  // README: pub type ListAuthorsRow { ListAuthorsRow(id: Int, name: String) }
  string.contains(rendered, "pub type ListAuthorsRow {")
  |> should.be_true()

  // README sqlode.embed: pub type GetBookWithAuthorRow {
  //   GetBookWithAuthorRow(authors: Author, title: String) }
  string.contains(rendered, "pub type GetBookWithAuthorRow {")
  |> should.be_true()
  string.contains(
    rendered,
    "GetBookWithAuthorRow(authors: Author, title: String)",
  )
  |> should.be_true()
}

pub fn readme_queries_snapshot_test() {
  let naming_ctx = naming.new()
  let block = readme_test_block()
  let analyzed = readme_analyzed_queries()
  let rendered = queries.render(naming_ctx, block, analyzed, dict.new(), False)

  // README: pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) { ... }
  string.contains(
    rendered,
    "pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) {",
  )
  |> should.be_true()

  // Parameterless query should use Nil type parameter
  string.contains(rendered, "pub fn list_authors() -> runtime.RawQuery(Nil) {")
  |> should.be_true()

  // README: pub fn create_author() -> runtime.RawQuery(params.CreateAuthorParams)
  string.contains(
    rendered,
    "pub fn create_author() -> runtime.RawQuery(params.CreateAuthorParams) {",
  )
  |> should.be_true()

  // QueryInfo is now in runtime, not generated inline
  string.contains(rendered, "pub type QueryInfo {")
  |> should.be_false()

  // all() uses runtime.QueryInfo
  string.contains(rendered, "pub fn all() -> List(runtime.QueryInfo) {")
  |> should.be_true()
}

fn readme_test_catalog() -> model.Catalog {
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/readme_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/readme_schema.sql", schema_content),
    ])
  catalog
}

fn readme_test_block() -> model.SqlBlock {
  model.SqlBlock(
    name: None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/readme_schema.sql"],
    queries: ["test/fixtures/readme_query.sql"],
    gleam: model.GleamOutput(
      out: "src/db",
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
      query_parameter_limit: option.None,
    ),
    overrides: model.empty_overrides(),
  )
}

fn readme_analyzed_queries() -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let catalog = readme_test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/readme_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/readme_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(result) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result
}

// --- Array type tests ---

pub fn array_schema_parsing_test() {
  let catalog = array_test_catalog()
  let assert [table] = catalog.tables
  let cols = table.columns
  // tags should be ArrayType(StringType)
  let assert [_, _, tags_col, scores_col] = cols
  tags_col.scalar_type |> should.equal(model.ArrayType(model.StringType))
  scores_col.scalar_type |> should.equal(model.ArrayType(model.IntType))
}

pub fn render_models_with_array_columns_test() {
  let naming_ctx = naming.new()
  let catalog = array_test_catalog()
  let analyzed = array_analyzed_queries()
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      analyzed,
      dict.new(),
      model.StringMapping,
      False,
    )

  // Table type should have List fields for array columns (nullable since no NOT NULL)
  string.contains(rendered, "tags: Option(List(String))")
  |> should.be_true()
  string.contains(rendered, "scores: Option(List(Int))")
  |> should.be_true()
}

pub fn render_params_with_array_columns_test() {
  let naming_ctx = naming.new()
  let analyzed = array_analyzed_queries()
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  // Params for CreateArticle should have array fields (nullable since no NOT NULL)
  string.contains(rendered, "tags: Option(List(String))")
  |> should.be_true()
  string.contains(rendered, "scores: Option(List(Int))")
  |> should.be_true()
}

pub fn render_params_array_encoding_raw_runtime_test() {
  let naming_ctx = naming.new()
  let analyzed = array_analyzed_queries()
  let rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )

  // Raw-mode array params should encode using runtime.array + list.map
  string.contains(rendered, "runtime.array(list.map(")
  |> should.be_true()

  // Nullable array params should use runtime.nullable wrapping runtime.array
  string.contains(rendered, "runtime.nullable(")
  |> should.be_true()

  // Should import gleam/list for array mapping
  string.contains(rendered, "import gleam/list")
  |> should.be_true()
}

pub fn render_pog_adapter_with_array_columns_test() {
  let naming_ctx = naming.new()
  let block =
    model.SqlBlock(
      name: None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/array_schema.sql"],
      queries: ["test/fixtures/array_query.sql"],
      gleam: model.GleamOutput(
        out: "src/db",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.empty_overrides(),
    )
  let analyzed = array_analyzed_queries()
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())

  // Decoder should use decode.list for array result columns
  string.contains(rendered, "decode.list(decode.string)")
  |> should.be_true()
  string.contains(rendered, "decode.list(decode.int)")
  |> should.be_true()

  // With `runtime.prepare`, parameter encoding of array columns lives
  // in the `params.*_values` function (which emits `runtime.array`).
  // The adapter just folds `runtime.Value`s through `value_to_pog`,
  // whose SqlArray case recurses with `pog.array(value_to_pog, ...)`.
  // So the adapter should contain the recursive helper, but not
  // `pog.array(pog.text)` / `pog.array(pog.int)` calls produced
  // per-param by the old codegen path.
  string.contains(rendered, "pog.array(value_to_pog, vs)") |> should.be_true()
  string.contains(rendered, "pog.array(pog.text)") |> should.be_false()
  string.contains(rendered, "pog.array(pog.int)") |> should.be_false()
}

fn array_test_catalog() -> model.Catalog {
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/array_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/array_schema.sql", schema_content),
    ])
  catalog
}

fn array_analyzed_queries() -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let catalog = array_test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/array_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/array_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(result) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result
}

pub fn out_to_module_path_strips_src_prefix_test() {
  common.out_to_module_path("src/db") |> should.equal("db")
  common.out_to_module_path("src/generated/db") |> should.equal("generated/db")
  common.out_to_module_path("/absolute/path/src/db") |> should.equal("db")
  common.out_to_module_path("/abs/src/generated/db")
  |> should.equal("generated/db")
  common.out_to_module_path("test_output/db") |> should.equal("test_output/db")
  // Multiple /src/ segments — take the part after the last /src/
  common.out_to_module_path("/home/src/project/src/db") |> should.equal("db")
  common.out_to_module_path("/home/src/project/src/generated/db")
  |> should.equal("generated/db")
}

fn analyzed_star_queries() -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let catalog = test_catalog()

  let sql = "-- name: GetAllAuthors :many\nSELECT * FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("star.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(result) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result
}

// --- escape_string tests ---

pub fn escape_string_backslash_test() {
  common.escape_string("a\\b") |> should.equal("a\\\\b")
}

pub fn escape_string_double_quote_test() {
  common.escape_string("say \"hello\"") |> should.equal("say \\\"hello\\\"")
}

pub fn escape_string_newline_and_tab_test() {
  common.escape_string("line1\nline2\ttab")
  |> should.equal("line1\\nline2\\ttab")
}

pub fn escape_string_carriage_return_test() {
  common.escape_string("a\rb") |> should.equal("a\\rb")
}

pub fn escape_string_no_special_chars_test() {
  common.escape_string("hello world") |> should.equal("hello world")
}

// --- README runtime example snapshot tests ---
// The README documents `runtime.prepare` and related runtime calls in code
// fences. These tests read the README file and lock in that the examples
// stay in sync with the actual runtime signatures, so a reader who
// copy-pastes the README does not hit an immediate compile error.

pub fn readme_runtime_prepare_is_two_arg_test() {
  // runtime.prepare signature: pub fn prepare(query, params) -> #(String, List(Value))
  // README must call it with exactly two arguments — the third "placeholder"
  // argument was removed because the dialect is baked into RawQuery itself.
  let assert Ok(readme) = simplifile.read("README.md")

  // The example explicitly uses the 2-arg call shape.
  string.contains(readme, "let #(sql, values) = runtime.prepare(")
  |> should.be_true()

  // Keep this resilient to README line-wrapping changes while still pinning
  // the second argument to the generated params record.
  string.contains(readme, "runtime.prepare(q, params.")
  |> should.be_true()

  // Fail fast if anyone regresses the example back to a 3-arg call with the
  // placeholder prefix string ("$" or "?").
  string.contains(readme, "\"$\",  // \"$\" for PostgreSQL")
  |> should.be_false()
}

// --- Issue #407: MySQL inline ENUM / SET codegen ---

fn mysql_enum_set_catalog() -> model.Catalog {
  let content =
    "CREATE TABLE items (
  id BIGINT NOT NULL,
  status ENUM('active', 'inactive', 'archived') NOT NULL,
  tags SET('red', 'green', 'blue')
);"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("items.sql", content)],
      model.MySQL,
    )
  catalog
}

pub fn render_mysql_inline_enum_emits_sum_type_test() {
  // A MySqlEnum EnumDef should emit a Gleam sum type + helpers, just
  // like a PostgresEnum. The column references the synthesized name
  // (`items_status` → `ItemsStatus`) so the generated models module
  // compiles against the table type.
  let naming_ctx = naming.new()
  let catalog = mysql_enum_set_catalog()
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      [],
      dict.new(),
      model.StringMapping,
      False,
    )

  string.contains(rendered, "pub type ItemsStatus {")
  |> should.be_true()
  string.contains(rendered, "Active")
  |> should.be_true()
  string.contains(rendered, "Inactive")
  |> should.be_true()
  string.contains(rendered, "Archived")
  |> should.be_true()
  string.contains(rendered, "pub fn items_status_to_string(")
  |> should.be_true()
  string.contains(rendered, "pub fn items_status_from_string(")
  |> should.be_true()
}

pub fn render_mysql_inline_set_emits_value_type_and_helpers_test() {
  // Issue #420: MySQL SET is now first-class in generated APIs. The
  // value type carries the constructors and the `_set_to_string` /
  // `_set_from_string` helpers translate the comma-joined wire format
  // to and from `List(<Name>Value)`.
  let naming_ctx = naming.new()
  let catalog = mysql_enum_set_catalog()
  let rendered =
    models.render(
      naming_ctx,
      catalog,
      [],
      dict.new(),
      model.StringMapping,
      False,
    )

  string.contains(rendered, "pub type ItemsTagsValue")
  |> should.be_true()
  string.contains(rendered, "items_tags_set_to_string")
  |> should.be_true()
  string.contains(rendered, "items_tags_set_from_string")
  |> should.be_true()
}

// --- Issue #418: MySQL native adapter codegen ---

pub fn render_mysql_native_adapter_uses_shork_test() {
  // The MySQL adapter is no longer a stub. It imports shork, binds
  // parameters via runtime.prepare → value_to_shork, and uses
  // shork.query / shork.returning / shork.execute as the execution
  // chain (mirroring the pog adapter shape).
  let naming_ctx = naming.new()
  let catalog = mysql_native_catalog()
  let queries = mysql_native_queries(naming_ctx, catalog)
  let block = mysql_native_block()
  let rendered = adapter.render(naming_ctx, block, queries, dict.new())

  string.contains(rendered, "import shork") |> should.be_true()
  string.contains(rendered, "value_to_shork") |> should.be_true()
  string.contains(rendered, "shork.query(") |> should.be_true()
  string.contains(rendered, "shork.execute(db)") |> should.be_true()
  // The stub message must not be present anywhere.
  string.contains(rendered, "MySQL adapter generation is not yet available")
  |> should.be_false()
  // SqlArray should panic instead of silently converting to null (#502)
  string.contains(rendered, "SqlArray is not supported in the MySQL native")
  |> should.be_true()
}

pub fn render_mysql_native_adapter_decodes_last_insert_id_test() {
  // :execlastid extracts shork's synthetic
  // [last_insert_id, affected_rows, warning_count] result row by
  // decoding column 0 as an int — no follow-up SELECT needed.
  let naming_ctx = naming.new()
  let catalog = mysql_native_catalog()
  let queries = mysql_native_queries(naming_ctx, catalog)
  let block = mysql_native_block()
  let rendered = adapter.render(naming_ctx, block, queries, dict.new())

  string.contains(rendered, "shork.returning({") |> should.be_true()
  string.contains(rendered, "decode.field(0, decode.int)") |> should.be_true()
}

pub fn render_mysql_native_adapter_decodes_affected_rows_for_execrows_test() {
  // :execrows extracts the affected-row count from column 1 of
  // shork's synthetic INSERT/UPDATE/DELETE result row.
  let naming_ctx = naming.new()
  let catalog = mysql_native_catalog()
  let queries = mysql_native_queries(naming_ctx, catalog)
  let block = mysql_native_block()
  let rendered = adapter.render(naming_ctx, block, queries, dict.new())

  string.contains(rendered, "decode.field(1, decode.int)") |> should.be_true()
}

pub fn render_mysql_native_adapter_passes_bytes_through_shork_ffi_test() {
  // SqlBytes encoding goes through `shork_ffi.coerce` directly so
  // BLOB / BINARY parameters reach mysql:query/4 byte-for-byte —
  // closes the previously-documented bytes round-trip gap from #418.
  let naming_ctx = naming.new()
  let catalog = mysql_native_catalog()
  let queries = mysql_native_queries(naming_ctx, catalog)
  let block = mysql_native_block()
  let rendered = adapter.render(naming_ctx, block, queries, dict.new())

  string.contains(rendered, "@external(erlang, \"shork_ffi\", \"coerce\")")
  |> should.be_true()
  string.contains(
    rendered,
    "fn bit_array_to_shork(value: BitArray) -> shork.Value",
  )
  |> should.be_true()
  string.contains(rendered, "runtime.SqlBytes(v) -> bit_array_to_shork(v)")
  |> should.be_true()
}

pub fn render_mysql_set_param_uses_set_to_string_helper_test() {
  // SET params are encoded via the generated `<name>_set_to_string`
  // helper before being handed to `runtime.string`; the column type
  // in the params record stays `List(<Name>Value)`.
  let naming_ctx = naming.new()
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/mysql_real_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("test/fixtures/mysql_real_schema.sql", schema_content)],
      model.MySQL,
    )
  let assert Ok(query_content) =
    simplifile.read("test/fixtures/mysql_real_query.sql")
  let assert Ok(parsed) =
    query_parser.parse_file(
      "test/fixtures/mysql_real_query.sql",
      model.MySQL,
      naming_ctx,
      query_content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, parsed)

  let params_rendered =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )
  // The params record exposes the SET column as `List(<Name>Value)`
  // and the encoder routes it through `<name>_set_to_string` before
  // calling `runtime.string`.
  string.contains(
    params_rendered,
    "tags: Option(List(models.AuthorsTagsValue))",
  )
  |> should.be_true()
  string.contains(params_rendered, "models.authors_tags_set_to_string")
  |> should.be_true()
}

pub fn render_mysql_set_decoder_uses_set_from_string_helper_test() {
  let naming_ctx = naming.new()
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/mysql_real_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("test/fixtures/mysql_real_schema.sql", schema_content)],
      model.MySQL,
    )
  let assert Ok(query_content) =
    simplifile.read("test/fixtures/mysql_real_query.sql")
  let assert Ok(parsed) =
    query_parser.parse_file(
      "test/fixtures/mysql_real_query.sql",
      model.MySQL,
      naming_ctx,
      query_content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, parsed)

  let block = mysql_native_block()
  let block =
    model.SqlBlock(
      ..block,
      schema: ["test/fixtures/mysql_real_schema.sql"],
      queries: ["test/fixtures/mysql_real_query.sql"],
    )
  let rendered = adapter.render(naming_ctx, block, analyzed, dict.new())
  string.contains(rendered, "models.authors_tags_set_from_string")
  |> should.be_true()
}

fn mysql_native_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/mysql_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("test/fixtures/mysql_schema.sql", content)],
      model.MySQL,
    )
  catalog
}

fn mysql_native_queries(
  naming_ctx: naming.NamingContext,
  catalog: model.Catalog,
) -> List(model.AnalyzedQuery) {
  let sql =
    "-- name: GetAuthor :one
SELECT id, name, bio, created_at FROM authors WHERE id = ?;
-- name: ListAuthors :many
SELECT id, name FROM authors ORDER BY id;
-- name: CreateAuthor :execlastid
INSERT INTO authors (name, bio, created_at) VALUES (?, ?, ?);
-- name: DeleteAuthor :exec
DELETE FROM authors WHERE id = ?;
-- name: UpdateBio :execrows
UPDATE authors SET bio = ? WHERE id = ?;
"
  let assert Ok(parsed) =
    query_parser.parse_file("q.sql", model.MySQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, parsed)
  analyzed
}

fn mysql_native_block() -> model.SqlBlock {
  model.SqlBlock(
    name: None,
    engine: model.MySQL,
    schema: ["test/fixtures/mysql_schema.sql"],
    queries: ["q.sql"],
    gleam: model.GleamOutput(
      out: "src/db",
      runtime: model.Native,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: True,
      query_parameter_limit: option.None,
    ),
    overrides: model.empty_overrides(),
  )
}
