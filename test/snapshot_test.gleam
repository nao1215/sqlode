//// Snapshot tests (birdie) for the code `sqlode generate` writes. Each
//// snapshot holds every file one sql block produces, in file-name order, as
//// the renderers emit them (before the CLI runs `gleam format`, so the
//// snapshots do not depend on the formatter of the Gleam on PATH).
////
//// A snapshot changes when a renderer, the type inference or the naming of
//// generated identifiers changes. Review the change with
//// `gleam run -m birdie` before accepting it; the accepted files live in
//// `test/birdie_snapshots/`. The unit tests in `codegen_test.gleam` and
//// `generate_test.gleam` pin single facts; these pin the whole output, so a
//// change nobody asserted on still shows up in review.

import birdie
import gleam/list
import gleam/option
import gleam/string
import simplifile
import sqlode/internal/generate
import sqlode/internal/model

const out_root = "test_output/snapshot_test"

fn generated(
  name: String,
  engine: model.Engine,
  runtime: model.Runtime,
  schema: String,
  queries: String,
) -> String {
  let out = out_root <> "/" <> name
  let _cleared = simplifile.delete(out)
  let block =
    model.SqlBlock(
      name: option.None,
      engine: engine,
      schema: ["test/fixtures/" <> schema],
      queries: ["test/fixtures/" <> queries],
      gleam: model.GleamOutput(
        out: out,
        runtime: runtime,
        type_mapping: model.StringMapping,
        emit_sql_as_comment: False,
        emit_exact_table_names: False,
        omit_unused_models: False,
        vendor_runtime: False,
        strict_views: False,
        query_parameter_limit: option.None,
      ),
      overrides: model.Overrides(type_overrides: [], column_renames: []),
    )
  let assert Ok(files) =
    generate.generate_config(model.Config(version: 2, sql: [block])).result
    as "the snapshot fixtures generate"
  files
  |> list.sort(string.compare)
  |> list.map(fn(path) {
    let assert Ok(content) = simplifile.read(path)
      as "a generated file is readable"
    let file = string.replace(path, out <> "/", "")
    "// ---- " <> file <> " ----\n" <> content
  })
  |> string.join("\n")
}

pub fn postgresql_native_snapshot_test() -> Nil {
  generated(
    "postgresql_native",
    model.PostgreSQL,
    model.Native,
    "postgresql_schema.sql",
    "postgresql_crud_query.sql",
  )
  |> birdie.snap(title: "generate, postgresql, native runtime, crud queries")
}

pub fn mysql_native_snapshot_test() -> Nil {
  generated(
    "mysql_native",
    model.MySQL,
    model.Native,
    "mysql_schema.sql",
    "mysql_query.sql",
  )
  |> birdie.snap(title: "generate, mysql, native runtime, crud queries")
}

pub fn sqlite_native_snapshot_test() -> Nil {
  generated(
    "sqlite_native",
    model.SQLite,
    model.Native,
    "sqlite_schema.sql",
    "sqlite_crud_query.sql",
  )
  |> birdie.snap(title: "generate, sqlite, native runtime, crud queries")
}

pub fn postgresql_raw_readme_snapshot_test() -> Nil {
  generated(
    "postgresql_raw",
    model.PostgreSQL,
    model.Raw,
    "readme_schema.sql",
    "readme_query.sql",
  )
  |> birdie.snap(title: "generate, postgresql, raw runtime, readme queries")
}

pub fn sqlite_raw_all_commands_snapshot_test() -> Nil {
  generated(
    "sqlite_all_commands",
    model.SQLite,
    model.Raw,
    "all_commands_schema.sql",
    "all_commands_query.sql",
  )
  |> birdie.snap(title: "generate, sqlite, raw runtime, every command")
}
