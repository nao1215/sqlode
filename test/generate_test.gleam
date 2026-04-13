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
          model.TypeOverride(db_type: "string", gleam_type: "Int"),
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
          model.TypeOverride(db_type: "STRING", gleam_type: "Float"),
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
          model.TypeOverride(db_type: "bool", gleam_type: "String"),
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
          model.TypeOverride(db_type: "int", gleam_type: "String"),
          model.TypeOverride(db_type: "string", gleam_type: "BitArray"),
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
          model.TypeOverride(db_type: "string", gleam_type: "BitArray"),
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
