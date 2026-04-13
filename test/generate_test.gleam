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
    gleam: model.GleamOutput(package: "db", out: test_out, runtime: model.Raw),
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

pub fn no_overrides_leaves_types_unchanged_test() {
  cleanup()
  let block = base_block(model.empty_overrides())

  run_generate(block)
  let models = read_generated("models.gleam")

  string.contains(models, "id: Int") |> should.be_true()
  string.contains(models, "name: String") |> should.be_true()

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
  // Original field pattern "id: Int, name: String" should be replaced
  string.contains(models, "id: Int, name: String") |> should.be_false()

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
      package: "db",
      out: join_rename_out,
      runtime: model.Raw,
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
    gleam: model.GleamOutput(package: "db", out: test_out, runtime: model.Raw),
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
      package: "db",
      out: all_commands_out,
      runtime: runtime,
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
  string.contains(queries, "runtime.QueryExecResult") |> should.be_true()
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
  // :execresult with params
  string.contains(params, "UpdatePostParams") |> should.be_true()
  // :execlastid with params
  string.contains(params, "InsertPostParams") |> should.be_true()
  // :many without params should still have type
  string.contains(params, "ListPostsParams") |> should.be_true()

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

  // :exec, :execresult, :execlastid should NOT generate row types
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
  // :execresult returns Nil (same as exec for sqlight)
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
        package: "db",
        out: "test_output/error_test",
        runtime: model.Raw,
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
        package: "db",
        out: "test_output/error_test",
        runtime: model.Raw,
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
      gleam: model.GleamOutput(package: "db", out: test_out, runtime: model.Raw),
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

// --- UNION/INTERSECT/EXCEPT tests ---

const compound_out = "test_output/generate_test_compound"

fn compound_block() -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.SQLite,
    schema: ["test/fixtures/compound_schema.sql"],
    queries: ["test/fixtures/compound_query.sql"],
    gleam: model.GleamOutput(
      package: "db",
      out: compound_out,
      runtime: model.Raw,
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
    gleam: model.GleamOutput(package: "db", out: view_out, runtime: model.Raw),
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
