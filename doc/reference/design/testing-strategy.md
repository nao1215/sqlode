# Testing Strategy

## Test stack

- Gleam unit tests (`gleam test`)
- ShellSpec CLI and compile-generation tests (`shellspec`)
- Integration test scripts (`integration_test/`)

## CI order (via `just all`)

1. `gleam format --check src/ test/`
2. `gleam check`
3. `gleam build --warnings-as-errors`
4. `gleam test`
5. `shellspec`

CI runs all five steps on every push and pull request via `.github/workflows/ci.yml`.

The integration test scripts (`integration_test/`) are **not** run in CI — they require manual execution because they create temporary Gleam projects and run `gleam build`/`gleam test` against real databases.

## 1. Gleam unit tests

### Current test layout

```text
test/
  config_test.gleam          — config loading, unsupported field rejection, error cases
  schema_parser_test.gleam   — DDL parsing, types, constraints, errors
  query_parser_test.gleam    — annotation parsing, placeholders, macros, errors
  query_analyzer_test.gleam  — param inference, result columns, JOINs, CTEs
  codegen_test.gleam         — params/models/queries/adapter rendering
  generate_test.gleam        — end-to-end generation pipeline
  naming_test.gleam          — case conversion, identifier normalization
  model_test.gleam           — type parsing, conversions, roundtrips
  runtime_test.gleam         — Value constructors
  sqlc_compat_test.gleam     — comprehensive SQL coverage (types, complex schemas, macros)
  dialect_test.gleam         — MySQL/SQLite dialect-specific analysis
  writer_test.gleam          — file writing
  sqlode_test.gleam          — test runner entry point
```

### Fixture strategy

Fixtures are kept in `test/fixtures/`:

- One schema/query pair per behavior
- Focused assertions per fixture
- Separate fixtures for each test domain (basic, complex, all-types, macros, dialects)

### Current fixture files

```text
test/fixtures/
  schema.sql                    — basic authors table
  query.sql                     — basic GetAuthor/ListAuthors
  create_query.sql              — INSERT query
  join_schema.sql               — authors + books for JOIN tests
  extended_schema.sql           — date/time/uuid/json types
  all_types_schema.sql          — all SQL type variants
  all_types_query.sql           — SELECT/INSERT for all types
  all_commands_schema.sql       — schema for all 6 command types
  all_commands_query.sql        — queries for :one/:many/:exec/:execresult/:execrows/:execlastid
  complex_schema.sql            — 6-table schema (users, posts, comments, etc.)
  complex_query.sql             — JOINs, RETURNING, UPDATE, DELETE
  compound_schema.sql           — compound query schema
  compound_query.sql            — compound queries (UNION, etc.)
  macro_edge_cases.sql          — duplicate args, mixed macros, slice
  macro_query.sql               — macro usage queries
  mysql_query.sql               — MySQL ? placeholder queries
  sqlite_query.sql              — SQLite ?N/:name/@name/$name queries
  sqlite_schema.sql             — SQLite-specific schema
  sqlite_crud_query.sql         — SQLite CRUD queries for integration tests
  typecast_schema.sql           — type cast test schema
  typecast_query.sql            — type cast expressions (::type)
  view_schema.sql               — CREATE VIEW schema
  view_query.sql                — queries against views
  sqlode.yaml                   — valid config fixture
  invalid_version.yaml          — version error fixture
  missing_engine.yaml           — missing field error fixture
  invalid_engine.yaml           — invalid value error fixture
  malformed.yaml                — invalid structure fixture
  missing_sql.yaml              — missing sql field fixture
  unsupported_root_field.yaml   — unsupported root-level config field
  unsupported_sql_field.yaml    — unsupported sql block config field
  unsupported_gen_field.yaml    — unsupported gen.gleam config field
  unsupported_multiple_fields.yaml — multiple unsupported fields
```

## 2. ShellSpec CLI and compile-generation tests

ShellSpec verifies the public CLI contract and that generated code compiles:

```text
spec/
  generate_spec.sh   — CLI help, error paths, successful generation
  compile_spec.sh    — generated code compilation (raw, pog native, sqlight native, all commands)
  spec_helper.sh     — shared helpers (project root, test output dir)
```

### CLI tests (`generate_spec.sh`)

- `--help` for generate command
- Invalid config path error
- Successful generation output (file existence and content checks)

### Compile-generation tests (`compile_spec.sh`)

Verifies that generated Gleam code compiles successfully by creating temporary Gleam projects and running `gleam build`:

- **Raw mode**: generates params + queries + models and verifies compilation
- **PostgreSQL native mode (pog)**: generates with pog adapter and verifies compilation
- **SQLite native mode (sqlight)**: generates with sqlight adapter and verifies compilation
- **All 6 command types (sqlight)**: verifies all query command variants compile

## 3. Integration tests

Integration test scripts live in `integration_test/` and are run manually (not in CI).

### Compile integration test (`compile_test.sh`)

Creates temporary Gleam projects and verifies generated code compiles:

- Raw mode with basic schema
- Raw mode with complex schema (6 tables, JOINs, RETURNING)
- Raw mode with all SQL types

### SQLite integration test (`sqlite_test.sh`)

Verifies generated adapter code works against a real SQLite database:

- Creates an in-memory SQLite database
- Generates sqlight adapter code
- Runs CRUD operations (create, read, list, delete) via generated adapter functions
- Verifies nullable field handling (NULL bio)
- Verifies non-existent record handling (returns None)

### Remaining coverage gaps

- **PostgreSQL integration**: no real database integration test yet (would require Docker)
- **MySQL integration**: deferred (no native Gleam MySQL adapter)
- **CI integration**: integration tests are not automated in CI due to build time and external dependencies
