import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import simplifile
import sqlode/generate
import sqlode/model

const test_out = "test_output/generate_test"

fn cleanup() {
  let _ = simplifile.delete(test_out)
  Nil
}

fn base_block(overrides: model.Overrides) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/schema.sql"],
    queries: ["test/fixtures/query.sql"],
    gleam: model.GleamOutput(
      out: test_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: overrides,
  )
}

fn run_generate(block: model.SqlBlock) -> List(String) {
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(files) = generate.generate_config(cfg)
  files
}

fn read_generated(filename: String) -> String {
  let assert Ok(content) = simplifile.read(test_out <> "/" <> filename)
  content
}

// --- Type override tests ---

pub fn type_override_changes_scalar_type_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "Int",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // "name" column is TEXT (StringType), override to Int
  string.contains(models, "name: Int") |> should.be_true()

  cleanup()
}

pub fn type_override_case_insensitive_db_type_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "STRING",
            gleam_type: "Float",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  string.contains(models, "name: Float") |> should.be_true()

  cleanup()
}

pub fn type_override_preserves_unmatched_columns_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "bool",
            gleam_type: "String",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // No bool columns in schema, so types should remain unchanged
  string.contains(models, "id: Int") |> should.be_true()
  string.contains(models, "name: String") |> should.be_true()

  cleanup()
}

pub fn type_override_multiple_overrides_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "String",
            nullable: option.None,
          ),
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "BitArray",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // id (IntType) → String, name (StringType) → BitArray
  string.contains(models, "id: String") |> should.be_true()
  string.contains(models, "name: BitArray") |> should.be_true()

  cleanup()
}

pub fn custom_type_override_preserves_type_name_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "UserId",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // id column is BIGSERIAL (IntType), override to UserId — should NOT become String
  string.contains(models, "id: UserId") |> should.be_true()

  cleanup()
}

pub fn custom_column_override_preserves_type_name_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.ColumnOverride(
            table: "authors",
            column: "name",
            gleam_type: "AuthorName",
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // name column should use the custom type name
  string.contains(models, "name: AuthorName") |> should.be_true()

  cleanup()
}

pub fn custom_type_override_adds_alias_warning_comment_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "UserId",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // generated models should contain the alias warning comment
  string.contains(models, "transparent type alias") |> should.be_true()
  string.contains(models, "Opaque types") |> should.be_true()

  cleanup()
}

pub fn no_custom_type_omits_alias_warning_comment_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  // no custom types, so no warning comment
  string.contains(models, "transparent type alias") |> should.be_false()

  cleanup()
}

pub fn module_qualified_custom_type_generates_import_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "myapp/types.UserId",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Should generate import for the module-qualified type
  string.contains(models, "import myapp/types.{type UserId}")
  |> should.be_true()
  // Should use the bare type name in declarations
  string.contains(models, "id: UserId") |> should.be_true()

  cleanup()
}

pub fn module_qualified_custom_type_in_params_generates_import_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "myapp/types.UserId",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let params = read_generated("params.gleam")

  // Params module should also import the module-qualified type
  string.contains(params, "import myapp/types.{type UserId}")
  |> should.be_true()

  cleanup()
}

pub fn bare_custom_type_omits_module_import_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "UserId",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Bare custom type should NOT generate a module import
  string.contains(models, "import myapp") |> should.be_false()
  // But should still use the type name
  string.contains(models, "id: UserId") |> should.be_true()

  cleanup()
}

pub fn no_overrides_leaves_types_unchanged_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  string.contains(models, "id: Int") |> should.be_true()
  string.contains(models, "name: String") |> should.be_true()

  cleanup()
}

// --- Rich type mapping tests ---

pub fn rich_type_mapping_emits_semantic_aliases_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/all_types_schema.sql"],
      queries: ["test/fixtures/all_types_query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.RichMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Semantic type aliases should be emitted
  string.contains(models, "pub type SqlTimestamp =") |> should.be_true()
  string.contains(models, "pub type SqlDate =") |> should.be_true()
  string.contains(models, "pub type SqlTime =") |> should.be_true()
  string.contains(models, "pub type SqlUuid =") |> should.be_true()
  string.contains(models, "pub type SqlJson =") |> should.be_true()

  // Fields should use semantic types
  string.contains(models, "col_timestamp: SqlTimestamp") |> should.be_true()
  string.contains(models, "col_date: SqlDate") |> should.be_true()
  string.contains(models, "col_time: SqlTime") |> should.be_true()
  string.contains(models, "col_uuid: SqlUuid") |> should.be_true()

  cleanup()
}

pub fn strong_type_mapping_emits_wrapper_types_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/all_types_schema.sql"],
      queries: ["test/fixtures/all_types_query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StrongMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Should emit wrapper types, not aliases
  string.contains(models, "pub type SqlUuid {\n  SqlUuid(String)\n}")
  |> should.be_true()
  string.contains(models, "pub type SqlTimestamp {\n  SqlTimestamp(String)\n}")
  |> should.be_true()

  // Should emit unwrap helper functions
  string.contains(models, "pub fn sql_uuid_to_string(value: SqlUuid) -> String")
  |> should.be_true()
  string.contains(
    models,
    "pub fn sql_timestamp_to_string(value: SqlTimestamp) -> String",
  )
  |> should.be_true()

  // Fields should use strong types
  string.contains(models, "col_uuid: SqlUuid") |> should.be_true()
  string.contains(models, "col_timestamp: SqlTimestamp") |> should.be_true()

  // Params should unwrap strong types
  let params = read_generated("params.gleam")
  string.contains(params, "models.sql_uuid_to_string(") |> should.be_true()

  cleanup()
}

pub fn string_type_mapping_does_not_emit_aliases_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  // No semantic aliases with StringMapping
  string.contains(models, "SqlTimestamp") |> should.be_false()
  string.contains(models, "SqlDate") |> should.be_false()
  string.contains(models, "SqlTime") |> should.be_false()
  string.contains(models, "SqlUuid") |> should.be_false()
  string.contains(models, "SqlJson") |> should.be_false()

  cleanup()
}

// --- Table record type tests ---

pub fn table_types_are_emitted_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  // Table type should be emitted from schema
  string.contains(models, "pub type Author {") |> should.be_true()
  string.contains(models, "bio: Option(String)") |> should.be_true()

  cleanup()
}

pub fn exact_table_match_produces_alias_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/star_query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Table type emitted
  string.contains(models, "pub type Author {") |> should.be_true()
  // Exact match should produce type alias
  string.contains(models, "pub type GetAllAuthorsRow =") |> should.be_true()
  // Should NOT have a separate record type for GetAllAuthorsRow
  string.contains(models, "pub type GetAllAuthorsRow {") |> should.be_false()

  cleanup()
}

pub fn partial_match_does_not_produce_alias_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  // Query selects only id, name (2 of 3 columns) — NOT an exact match
  string.contains(models, "pub type GetAuthorRow {") |> should.be_true()
  string.contains(models, "pub type GetAuthorRow =") |> should.be_false()

  cleanup()
}

// --- Column rename tests ---

pub fn column_rename_changes_field_name_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(type_overrides: [], column_renames: [
        model.ColumnRename(
          table: "authors",
          column: "name",
          rename_to: "author_name",
        ),
      ]),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  string.contains(models, "author_name: String") |> should.be_true()
  // Row type should use renamed field, not original
  string.contains(models, "GetAuthorRow(id: Int, name: String)")
  |> should.be_false()
  string.contains(models, "GetAuthorRow(id: Int, author_name: String)")
  |> should.be_true()

  cleanup()
}

pub fn column_rename_case_insensitive_match_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(type_overrides: [], column_renames: [
        model.ColumnRename(
          table: "authors",
          column: "NAME",
          rename_to: "full_name",
        ),
      ]),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  string.contains(models, "full_name: String") |> should.be_true()

  cleanup()
}

pub fn column_rename_only_applies_to_matching_table_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(type_overrides: [], column_renames: [
        model.ColumnRename(
          table: "posts",
          column: "name",
          rename_to: "post_name",
        ),
      ]),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Rename for "posts" table should not affect "authors" queries
  string.contains(models, "name: String") |> should.be_true()
  string.contains(models, "post_name") |> should.be_false()

  cleanup()
}

pub fn combined_type_override_and_column_rename_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "BitArray",
            nullable: option.None,
          ),
        ],
        column_renames: [
          model.ColumnRename(
            table: "authors",
            column: "name",
            rename_to: "display_name",
          ),
        ],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Both override and rename should apply
  string.contains(models, "display_name: BitArray") |> should.be_true()

  cleanup()
}

// --- JOIN column rename regression test (issue #84) ---

const join_rename_out = "test_output/generate_test_join_rename"

fn join_rename_block(renames: List(model.ColumnRename)) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/join_schema.sql"],
    queries: ["test/fixtures/join_rename_query.sql"],
    gleam: model.GleamOutput(
      out: join_rename_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.Overrides(type_overrides: [], column_renames: renames),
  )
}

fn cleanup_join_rename() {
  let _ = simplifile.delete(join_rename_out)
  Nil
}

pub fn join_rename_only_renames_matching_table_column_test() {
  cleanup_join_rename()
  let block =
    join_rename_block([
      model.ColumnRename(table: "authors", column: "id", rename_to: "author_id"),
    ])

  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(join_rename_out <> "/models.gleam")

  // authors.id should be renamed to author_id
  string.contains(models, "author_id: Int") |> should.be_true()
  // books.id should remain as id (not renamed)
  string.contains(models, "id: Int") |> should.be_true()
  // title should be unaffected
  string.contains(models, "title: String") |> should.be_true()

  cleanup_join_rename()
}

pub fn join_rename_does_not_rename_wrong_table_column_test() {
  cleanup_join_rename()
  let block =
    join_rename_block([
      model.ColumnRename(table: "books", column: "id", rename_to: "book_id"),
    ])

  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(join_rename_out <> "/models.gleam")

  // books.id should be renamed to book_id
  string.contains(models, "book_id: Int") |> should.be_true()
  // authors.id should remain as id
  string.contains(models, "id: Int") |> should.be_true()

  cleanup_join_rename()
}

// --- Column-level type override tests ---

pub fn column_override_changes_specific_column_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.ColumnOverride(
            table: "authors",
            column: "id",
            gleam_type: "String",
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // id column should be overridden to String
  string.contains(models, "id: String") |> should.be_true()

  cleanup()
}

pub fn column_override_takes_precedence_over_db_type_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "int",
            gleam_type: "Float",
            nullable: option.None,
          ),
          model.ColumnOverride(
            table: "authors",
            column: "id",
            gleam_type: "String",
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Column override (String) should win over db_type override (Float)
  string.contains(models, "id: String") |> should.be_true()

  cleanup()
}

pub fn column_override_does_not_affect_other_tables_test() {
  cleanup()
  let block =
    base_block(
      model.Overrides(
        type_overrides: [
          model.ColumnOverride(
            table: "posts",
            column: "id",
            gleam_type: "String",
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Override for posts.id should not affect authors.id
  string.contains(models, "id: Int") |> should.be_true()

  cleanup()
}

// --- Nullable-specific type override tests ---

fn nullable_block(overrides: model.Overrides) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.SQLite,
    schema: ["test/fixtures/sqlite_schema.sql"],
    queries: ["test/fixtures/sqlite_crud_query.sql"],
    gleam: model.GleamOutput(
      out: test_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: overrides,
  )
}

pub fn nullable_override_applies_only_to_nullable_columns_test() {
  cleanup()
  // Override string type only for nullable columns
  let block =
    nullable_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "BitArray",
            nullable: option.Some(True),
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // bio is nullable TEXT → should be overridden to BitArray
  string.contains(models, "bio: Option(BitArray)") |> should.be_true()
  // name is NOT NULL TEXT → should remain String
  string.contains(models, "name: String") |> should.be_true()

  cleanup()
}

pub fn non_nullable_override_applies_only_to_non_nullable_columns_test() {
  cleanup()
  let block =
    nullable_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "BitArray",
            nullable: option.Some(False),
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // name is NOT NULL TEXT → should be overridden to BitArray
  string.contains(models, "name: BitArray") |> should.be_true()
  // bio is nullable TEXT → should remain Option(String)
  string.contains(models, "bio: Option(String)") |> should.be_true()

  cleanup()
}

pub fn nullable_none_override_applies_to_all_test() {
  cleanup()
  let block =
    nullable_block(
      model.Overrides(
        type_overrides: [
          model.DbTypeOverride(
            db_type: "string",
            gleam_type: "BitArray",
            nullable: option.None,
          ),
        ],
        column_renames: [],
      ),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // Both nullable and non-nullable string columns should be overridden
  string.contains(models, "name: BitArray") |> should.be_true()
  string.contains(models, "bio: Option(BitArray)") |> should.be_true()

  cleanup()
}

// --- All 6 query command types tests ---

const all_commands_out = "test_output/generate_test_commands"

fn all_commands_block(
  engine: model.Engine,
  runtime: model.Runtime,
) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: engine,
    schema: ["test/fixtures/all_commands_schema.sql"],
    queries: ["test/fixtures/all_commands_query.sql"],
    gleam: model.GleamOutput(
      out: all_commands_out,
      runtime: runtime,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

fn cleanup_commands() {
  let _ = simplifile.delete(all_commands_out)
  Nil
}

fn read_commands_file(filename: String) -> String {
  let assert Ok(content) = simplifile.read(all_commands_out <> "/" <> filename)
  content
}

pub fn all_commands_generate_queries_test() {
  cleanup_commands()
  let block = all_commands_block(model.SQLite, model.Raw)
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let queries = read_commands_file("queries.gleam")

  // All 6 query functions should exist
  string.contains(queries, "pub fn get_post()") |> should.be_true()
  string.contains(queries, "pub fn list_posts()") |> should.be_true()
  string.contains(queries, "pub fn create_post()") |> should.be_true()
  string.contains(queries, "pub fn update_post()") |> should.be_true()
  string.contains(queries, "pub fn count_posts()") |> should.be_true()
  string.contains(queries, "pub fn insert_post()") |> should.be_true()

  // Verify command types
  string.contains(queries, "runtime.QueryOne") |> should.be_true()
  string.contains(queries, "runtime.QueryMany") |> should.be_true()
  string.contains(queries, "runtime.QueryExec") |> should.be_true()
  string.contains(queries, "runtime.QueryExecRows") |> should.be_true()
  string.contains(queries, "runtime.QueryExecLastId") |> should.be_true()

  cleanup_commands()
}

pub fn all_commands_generate_params_test() {
  cleanup_commands()
  let block = all_commands_block(model.SQLite, model.Raw)
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let params = read_commands_file("params.gleam")

  // :one and :many with params
  string.contains(params, "GetPostParams") |> should.be_true()
  // :exec with params
  string.contains(params, "CreatePostParams") |> should.be_true()
  string.contains(params, "UpdatePostParams") |> should.be_true()
  // :execlastid with params
  string.contains(params, "InsertPostParams") |> should.be_true()
  // :many without params should NOT generate Params type
  string.contains(params, "ListPostsParams") |> should.be_false()

  cleanup_commands()
}

pub fn all_commands_generate_models_test() {
  cleanup_commands()
  let block = all_commands_block(model.SQLite, model.Raw)
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let models = read_commands_file("models.gleam")

  // :one and :many generate row types
  string.contains(models, "GetPostRow") |> should.be_true()
  string.contains(models, "ListPostsRow") |> should.be_true()

  // :exec, :execlastid should NOT generate row types
  string.contains(models, "CreatePostRow") |> should.be_false()
  string.contains(models, "UpdatePostRow") |> should.be_false()
  string.contains(models, "InsertPostRow") |> should.be_false()

  cleanup_commands()
}

pub fn all_commands_sqlight_adapter_test() {
  cleanup_commands()
  let block = all_commands_block(model.SQLite, model.Native)
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)

  let adapter = read_commands_file("sqlight_adapter.gleam")

  // :one returns Option
  string.contains(adapter, "Result(Option(models.GetPostRow)")
  |> should.be_true()
  // :many returns List
  string.contains(adapter, "Result(List(models.ListPostsRow)")
  |> should.be_true()
  // :exec returns Nil
  string.contains(adapter, "fn create_post(") |> should.be_true()
  string.contains(adapter, "Result(Nil, sqlight.Error)") |> should.be_true()
  // :exec returns Nil
  string.contains(adapter, "fn update_post(") |> should.be_true()
  // :execrows returns Int
  string.contains(adapter, "fn count_posts(") |> should.be_true()
  string.contains(adapter, "Result(Int, sqlight.Error)") |> should.be_true()
  // :execlastid returns Nil (same as exec for sqlight)
  string.contains(adapter, "fn insert_post(") |> should.be_true()

  cleanup_commands()
}

// --- Error path tests ---

pub fn run_with_missing_config_test() {
  let result = generate.run("nonexistent_config.yaml")
  case result {
    Error(generate.ConfigError(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn run_with_missing_schema_file_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["nonexistent_schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/error_test",
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.SchemaReadError(..)) -> Nil
    _ -> should.fail()
  }
}

pub fn run_with_missing_query_file_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["nonexistent_query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/error_test",
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.QueryReadError(..)) -> Nil
    _ -> should.fail()
  }
}

pub fn run_with_no_queries_in_file_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/schema.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.NoQueriesGenerated(..)) -> Nil
    _ -> should.fail()
  }
  cleanup()
}

pub fn execresult_rejected_on_native_runtime_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.SQLite,
      schema: ["test/fixtures/all_commands_schema.sql"],
      queries: ["test/fixtures/execresult_query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/execresult_reject",
        runtime: model.Native,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.UnsupportedAnnotation(..)) -> Nil
    _ -> should.fail()
  }
}

pub fn execresult_allowed_on_raw_runtime_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.SQLite,
      schema: ["test/fixtures/all_commands_schema.sql"],
      queries: ["test/fixtures/execresult_query.sql"],
      gleam: model.GleamOutput(
        out: "test_output/execresult_raw",
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(_) = generate.generate_config(cfg)
  let _ = simplifile.delete("test_output/execresult_raw")
  Nil
}

// --- Unsupported batch/copyfrom annotation rejection tests ---

fn unsupported_annotation_block(query_file: String) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.SQLite,
    schema: ["test/fixtures/all_commands_schema.sql"],
    queries: [query_file],
    gleam: model.GleamOutput(
      out: "test_output/unsupported_reject",
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn batchone_rejected_test() {
  let block = unsupported_annotation_block("test/fixtures/batchone_query.sql")
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.UnsupportedAnnotation(command: ":batchone", ..)) -> Nil
    _ -> should.fail()
  }
}

pub fn batchmany_rejected_test() {
  let block = unsupported_annotation_block("test/fixtures/batchmany_query.sql")
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.UnsupportedAnnotation(command: ":batchmany", ..)) -> Nil
    _ -> should.fail()
  }
}

pub fn batchexec_rejected_test() {
  let block = unsupported_annotation_block("test/fixtures/batchexec_query.sql")
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.UnsupportedAnnotation(command: ":batchexec", ..)) -> Nil
    _ -> should.fail()
  }
}

pub fn copyfrom_rejected_test() {
  let block = unsupported_annotation_block("test/fixtures/copyfrom_query.sql")
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  case result {
    Error(generate.UnsupportedAnnotation(command: ":copyfrom", ..)) -> Nil
    _ -> should.fail()
  }
}

// --- UNION/INTERSECT/EXCEPT tests ---

const compound_out = "test_output/generate_test_compound"

fn compound_block() -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.SQLite,
    schema: ["test/fixtures/compound_schema.sql"],
    queries: ["test/fixtures/compound_query.sql"],
    gleam: model.GleamOutput(
      out: compound_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

fn cleanup_compound() {
  let _ = simplifile.delete(compound_out)
  Nil
}

pub fn union_all_infers_columns_from_first_select_test() {
  cleanup_compound()
  let cfg = model.Config(version: 2, sql: [compound_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(compound_out <> "/models.gleam")

  // GetAllItems should have columns from the first SELECT (products table)
  string.contains(models, "GetAllItemsRow") |> should.be_true()
  string.contains(models, "id: Int") |> should.be_true()
  string.contains(models, "name: String") |> should.be_true()
  string.contains(models, "price: Float") |> should.be_true()

  cleanup_compound()
}

pub fn union_infers_columns_test() {
  cleanup_compound()
  let cfg = model.Config(version: 2, sql: [compound_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(compound_out <> "/models.gleam")

  // GetUniqueNames should have the single column from first SELECT
  string.contains(models, "GetUniqueNamesRow") |> should.be_true()

  cleanup_compound()
}

pub fn intersect_infers_columns_test() {
  cleanup_compound()
  let cfg = model.Config(version: 2, sql: [compound_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(compound_out <> "/models.gleam")

  string.contains(models, "GetProductOnlyRow") |> should.be_true()

  cleanup_compound()
}

pub fn except_infers_columns_test() {
  cleanup_compound()
  let cfg = model.Config(version: 2, sql: [compound_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(compound_out <> "/models.gleam")

  string.contains(models, "GetExclusiveProductsRow") |> should.be_true()

  cleanup_compound()
}

// --- VIEW tests ---

const view_out = "test_output/generate_test_view"

fn view_block() -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.SQLite,
    schema: ["test/fixtures/view_schema.sql"],
    queries: ["test/fixtures/view_query.sql"],
    gleam: model.GleamOutput(
      out: view_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

fn cleanup_view() {
  let _ = simplifile.delete(view_out)
  Nil
}

pub fn view_select_columns_inferred_test() {
  cleanup_view()
  let cfg = model.Config(version: 2, sql: [view_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(view_out <> "/models.gleam")

  // Query referencing active_authors view should have typed columns
  string.contains(models, "GetActiveAuthorRow") |> should.be_true()
  string.contains(models, "id: Int") |> should.be_true()
  string.contains(models, "name: String") |> should.be_true()

  cleanup_view()
}

pub fn view_select_star_inferred_test() {
  cleanup_view()
  let cfg = model.Config(version: 2, sql: [view_block()])
  let assert Ok(_) = generate.generate_config(cfg)

  let assert Ok(models) = simplifile.read(view_out <> "/models.gleam")

  // Query referencing full_authors view (SELECT *) should have all columns
  string.contains(models, "ListFullAuthorsRow") |> should.be_true()
  string.contains(models, "bio: Option(String)") |> should.be_true()

  cleanup_view()
}

// --- Config path resolution tests ---

const resolve_out = "src/resolve_paths_test"

fn cleanup_resolve() {
  let _ = simplifile.delete(resolve_out)
  Nil
}

pub fn run_resolves_paths_relative_to_config_dir_test() {
  cleanup_resolve()
  let assert Ok(files) =
    generate.run("test/fixtures/subdir/sqlode_relative.yaml")

  // schema and queries are resolved relative to config dir (test/fixtures/subdir/)
  // so ../schema.sql and ../query.sql resolve to test/fixtures/schema.sql etc.
  list.length(files) |> should.equal(3)

  let assert Ok(models) = simplifile.read(resolve_out <> "/models.gleam")
  string.contains(models, "Author") |> should.be_true()

  cleanup_resolve()
}

pub fn invalid_out_path_rejected_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: "/tmp/invalid_absolute_path",
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )
  let cfg = model.Config(version: 2, sql: [block])
  let result = generate.generate_config(cfg)
  result |> should.be_error()
}

// --- Directory input tests ---

const dir_out = "test_output/generate_test_dir"

fn cleanup_dir() {
  let _ = simplifile.delete(dir_out)
  Nil
}

pub fn accept_directory_for_schema_and_queries_test() {
  cleanup_dir()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema_dir"],
      queries: ["test/fixtures/query_dir"],
      gleam: model.GleamOutput(
        out: dir_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(files) = generate.generate_config(cfg)

  list.length(files) |> should.equal(3)

  let assert Ok(models) = simplifile.read(dir_out <> "/models.gleam")
  string.contains(models, "Author") |> should.be_true()

  cleanup_dir()
}

pub fn mixed_file_and_directory_inputs_test() {
  cleanup_dir()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query_dir"],
      gleam: model.GleamOutput(
        out: dir_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  let cfg = model.Config(version: 2, sql: [block])
  let assert Ok(files) = generate.generate_config(cfg)

  list.length(files) |> should.equal(3)

  cleanup_dir()
}

pub fn reject_empty_schema_directory_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/empty_dir"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: dir_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  let cfg = model.Config(version: 2, sql: [block])
  let assert Error(error) = generate.generate_config(cfg)

  generate.error_to_string(error)
  |> string.contains("no .sql files")
  |> should.be_true
}

pub fn reject_empty_query_directory_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/empty_dir"],
      gleam: model.GleamOutput(
        out: dir_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  let cfg = model.Config(version: 2, sql: [block])
  let assert Error(error) = generate.generate_config(cfg)

  generate.error_to_string(error)
  |> string.contains("no .sql files")
  |> should.be_true
}

// --- Duplicate query name tests ---

pub fn reject_duplicate_query_names_test() {
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/duplicate_query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  let cfg = model.Config(version: 2, sql: [block])
  let assert Error(error) = generate.generate_config(cfg)

  generate.error_to_string(error)
  |> string.contains("duplicate query name \"GetAuthor\"")
  |> should.be_true
}

// --- emit_sql_as_comment / emit_exact_table_names coverage ---

pub fn emit_sql_as_comment_includes_sql_in_output_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: True,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  run_generate(block)
  let queries = read_generated("queries.gleam")

  queries
  |> string.contains("// SQL: ")
  |> should.be_true

  cleanup()
}

pub fn omits_sql_comment_by_default_test() {
  cleanup()
  run_generate(base_block(model.empty_overrides()))
  let queries = read_generated("queries.gleam")

  queries
  |> string.contains("// SQL: ")
  |> should.be_false

  cleanup()
}

pub fn emit_exact_table_names_skips_singularization_test() {
  cleanup()
  let block =
    model.SqlBlock(
      name: option.None,
      engine: model.PostgreSQL,
      schema: ["test/fixtures/schema.sql"],
      queries: ["test/fixtures/query.sql"],
      gleam: model.GleamOutput(
        out: test_out,
        runtime: model.Raw,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: True,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
      ),
      overrides: model.empty_overrides(),
    )

  run_generate(block)
  let models = read_generated("models.gleam")

  // "authors" table stays "Authors" rather than being singularized to "Author"
  models
  |> string.contains("pub type Authors {")
  |> should.be_true

  cleanup()
}

pub fn singularizes_table_names_by_default_test() {
  cleanup()
  run_generate(base_block(model.empty_overrides()))
  let models = read_generated("models.gleam")

  // Default: "authors" singularizes to "Author"
  models
  |> string.contains("pub type Author {")
  |> should.be_true

  cleanup()
}

// omit_unused_models tests (Issue #364)

fn multi_table_block(omit_unused_models: Bool) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/multi_table_schema.sql"],
    queries: ["test/fixtures/multi_table_query.sql"],
    gleam: model.GleamOutput(
      out: test_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: omit_unused_models,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn omit_unused_models_default_keeps_all_tables_test() {
  cleanup()
  run_generate(multi_table_block(False))
  let models = read_generated("models.gleam")

  // Default behaviour: both tables and both enums remain in models.gleam.
  string.contains(models, "pub type Author {") |> should.be_true
  string.contains(models, "pub type UnusedTable {") |> should.be_true
  string.contains(models, "pub type UsedStatus {") |> should.be_true
  string.contains(models, "pub type UnusedStatus {") |> should.be_true

  cleanup()
}

pub fn omit_unused_models_drops_unreferenced_tables_test() {
  cleanup()
  run_generate(multi_table_block(True))
  let models = read_generated("models.gleam")

  // The referenced table/enum stay.
  string.contains(models, "pub type Author {") |> should.be_true
  string.contains(models, "pub type UsedStatus {") |> should.be_true

  // The unused table and its enum are dropped.
  string.contains(models, "pub type UnusedTable {") |> should.be_false
  string.contains(models, "pub type UnusedStatus {") |> should.be_false

  cleanup()
}

// vendor_runtime tests (Issue #302)

fn vendor_runtime_block(vendor_runtime: Bool) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/schema.sql"],
    queries: ["test/fixtures/query.sql"],
    gleam: model.GleamOutput(
      out: test_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: vendor_runtime,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn vendor_runtime_default_imports_shared_runtime_test() {
  cleanup()
  run_generate(vendor_runtime_block(False))
  let params = read_generated("params.gleam")
  let queries = read_generated("queries.gleam")
  let exists = case simplifile.read(test_out <> "/runtime.gleam") {
    Ok(_) -> True
    Error(_) -> False
  }

  // Default behaviour: import sqlode/runtime, no vendored file.
  string.contains(params, "import sqlode/runtime.{type Value}")
  |> should.be_true
  string.contains(queries, "import sqlode/runtime") |> should.be_true
  exists |> should.be_false

  cleanup()
}

pub fn vendor_runtime_emits_local_copy_and_rewrites_imports_test() {
  cleanup()
  run_generate(vendor_runtime_block(True))
  let params = read_generated("params.gleam")
  let queries = read_generated("queries.gleam")
  let runtime = read_generated("runtime.gleam")
  let actual_runtime = case simplifile.read("src/sqlode/runtime.gleam") {
    Ok(content) -> content
    Error(_) -> ""
  }

  // Vendored: imports point at the local copy and no sqlode/runtime
  // reference leaks through.
  string.contains(params, "import sqlode/runtime") |> should.be_false
  string.contains(params, "import") |> should.be_true
  string.contains(queries, "import sqlode/runtime") |> should.be_false

  // The local copy must end up identical to the sqlode/runtime source,
  // byte-for-byte, so the same API the generated code expects is
  // available. The module_path prefix is applied at import sites, not
  // inside the runtime file itself.
  runtime |> should.equal(actual_runtime)

  cleanup()
}

// strict_views tests

fn strict_views_block(strict_views: Bool) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: ["test/fixtures/strict_views_schema.sql"],
    queries: ["test/fixtures/strict_views_query.sql"],
    gleam: model.GleamOutput(
      out: test_out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: strict_views,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn strict_views_true_rejects_unresolvable_view_test() {
  cleanup()
  let cfg = model.Config(version: 2, sql: [strict_views_block(True)])
  case generate.generate_config(cfg) {
    Error(generate.SchemaParseError(detail)) -> {
      string.contains(detail, "strict_views") |> should.be_true
      string.contains(detail, "unknown_column") |> should.be_true
    }
    Error(other) -> {
      // Any other error means the strict_views gate did not fire first.
      panic as { "expected SchemaParseError, got " <> string.inspect(other) }
    }
    Ok(_) -> panic as "expected SchemaParseError when strict_views is True"
  }
  cleanup()
}

pub fn strict_views_false_preserves_legacy_silent_drop_test() {
  cleanup()
  // With strict_views disabled, the unresolvable view is silently dropped
  // and generation proceeds. generate_config must succeed for the
  // resolvable parts of the schema.
  let cfg = model.Config(version: 2, sql: [strict_views_block(False)])
  let assert Ok(_) = generate.generate_config(cfg)
  cleanup()
}
