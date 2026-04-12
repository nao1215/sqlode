# Testing Strategy

## Test stack

- Gleam unit tests (`gleam test`)
- ShellSpec CLI tests (`shellspec`)

## CI order (via `just all`)

1. `gleam format --check src/ test/`
2. `gleam check`
3. `gleam build --warnings-as-errors`
4. `gleam test`
5. `shellspec`

## 1. Gleam unit tests

### Current test layout

```text
test/
  config_test.gleam          — config loading, error cases
  schema_parser_test.gleam   — DDL parsing, types, constraints, errors
  query_parser_test.gleam    — annotation parsing, placeholders, macros, errors
  query_analyzer_test.gleam  — param inference, result columns, JOINs, CTEs
  codegen_test.gleam         — params/models/queries/adapter rendering
  naming_test.gleam          — case conversion, identifier normalization
  model_test.gleam           — type parsing, conversions, roundtrips
  runtime_test.gleam         — Value constructors
  sqlc_compat_test.gleam     — comprehensive SQL coverage (types, complex schemas, macros)
  dialect_test.gleam         — MySQL/SQLite dialect-specific analysis
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
  schema.sql              — basic authors table
  query.sql               — basic GetAuthor/ListAuthors
  create_query.sql        — INSERT query
  join_schema.sql         — authors + books for JOIN tests
  extended_schema.sql     — date/time/uuid/json types
  all_types_schema.sql    — all 23 SQL type variants
  all_types_query.sql     — SELECT/INSERT for all types
  complex_schema.sql      — 6-table schema (users, posts, comments, etc.)
  complex_query.sql       — JOINs, RETURNING, UPDATE, DELETE
  macro_edge_cases.sql    — duplicate args, mixed macros, slice
  mysql_query.sql         — MySQL ? placeholder queries
  sqlite_query.sql        — SQLite ?N/:name/@name/$name queries
  sqlode.yaml             — valid config fixture
  invalid_version.yaml    — version error fixture
  missing_engine.yaml     — missing field error fixture
  invalid_engine.yaml     — invalid value error fixture
  malformed.yaml          — invalid structure fixture
  missing_sql.yaml        — missing sql field fixture
```

## 2. ShellSpec CLI tests

ShellSpec verifies the public CLI contract:

```text
spec/
  generate_spec.sh   — CLI help, error paths, successful generation
  spec_helper.sh     — shared helpers (project root, test output dir)
```

### Current coverage

- `--help` for generate command
- invalid config path error
- successful generation output (file existence and content checks)

## 3. Integration tests (planned)

Not yet implemented. See Issues #16 and #17:

- **Issue #16**: Verify generated Gleam code compiles
- **Issue #17**: SQLite integration test with real database connection

### Planned approach

- SQLite: local file-backed test (no Docker needed)
- PostgreSQL: Docker-based
- MySQL: deferred (no native adapter)
