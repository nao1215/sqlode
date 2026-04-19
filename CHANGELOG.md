# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **MySQL completeness pass.** Closes the documented gaps left over
  from the #417 epic:
  - `BLOB` / `BINARY` columns now round-trip byte-for-byte in native
    mode by routing `SqlBytes` through `shork_ffi.coerce` (an internal
    FFI binding mirroring shork's own `text` / `int` constructors).
  - The MySQL `SET(...)` column type is now wired end-to-end. The
    generated params record exposes the field as `List(<Name>Value)`
    and the encoder routes it through the new `<name>_set_to_string`
    helper; the adapter decoder calls `<name>_set_from_string` on
    the wire string.
  - The MySQL real-DB integration lane now exercises bytes, decimal
    (lossless `DecimalType`), enum, and SET round-trips against the
    live MySQL service.
  - MySQL schema files containing DDL sqlode does not (yet) model
    fail with a new `UnsupportedMysqlDdl` parse error rather than
    silently dropping the statement on the floor (Issue #419
    fail-fast acceptance).
  - `:execresult` rejection on `runtime: "native"` is now pinned by
    a MySQL-specific test (positive: same query in `runtime: "raw"`
    generates without complaint).

### Added

- **End-to-end MySQL support** (#417 epic; #418, #419, #420, #421,
  #422, #423). MySQL is now a first-class engine in both `raw` and
  `native` runtime modes. The native MySQL adapter targets the
  [`shork`](https://hexdocs.pm/shork/) Hex package; `:execrows` and
  `:execlastid` resolve via `SELECT ROW_COUNT()` / `SELECT
  LAST_INSERT_ID()` follow-up queries. The previous config guard
  rejecting `engine: "mysql"` + `runtime: "native"` is gone.
- **Modifier-aware MySQL type contract** (#420). `TINYINT(1)` and
  `BOOLEAN` resolve to `BoolType`, `UNSIGNED` / `SIGNED` /
  `ZEROFILL` noise no longer blocks classification, and a new
  `DecimalType` keeps `DECIMAL` / `NUMERIC` columns lossless (a
  `String` Gleam type) instead of silently collapsing into `Float`.
  MySQL `SET(...)` columns are now first-class `SetType(name)` and
  surface as `List(<Name>Value)` in generated code, with
  `_set_to_string` / `_set_from_string` helpers for the comma-joined
  wire format.
- **MySQL migration DDL** (#419). `ALTER TABLE ... MODIFY COLUMN`
  rewrites a column's type and nullability; `ALTER TABLE ... CHANGE
  COLUMN` renames and retypes in one step. Multi-file migration
  fixtures see the catalog from previously-parsed files, so an ALTER
  in `002_*.sql` can operate on a CREATE TABLE in `001_*.sql`.
  `AUTO_INCREMENT`, `ON UPDATE CURRENT_TIMESTAMP`, `CHARACTER SET`,
  `COLLATE`, `COMMENT`, and `VISIBLE`/`INVISIBLE` no longer bleed
  into column-type classification.
- **MySQL query parity fixtures** (#421). A dedicated MySQL advanced
  fixture pins the supported query subset: backtick-quoted
  identifiers, `LIMIT offset, count`, `INSERT ... ON DUPLICATE KEY
  UPDATE` (without phantom params from `VALUES(...)` references), CTE
  + JOIN result-column resolution, and `sqlode.slice` expansion
  through positional placeholders.
- **MySQL integration lanes** (#422). Three new integration cases —
  `case_mysql_compile_raw`, `case_mysql_compile_native`, and
  `case_mysql_real` — exercise the generated MySQL adapter against
  pinned dependencies and a live MySQL 8.0 service container. CI
  provisions MySQL 8.0 alongside the existing PostgreSQL service.
- **Per-engine/runtime capability matrix** (#423).
  `doc/capabilities.md` now expresses support at engine/runtime
  granularity (raw/native flag plus the Hex driver each native
  adapter imports) instead of relying on the flat engine list to
  imply parity.

## [0.4.0] - 2026-04-19

### Added

- **Engine-aware expression parser with MySQL clause preservation**
  (#405). `expr_parser.parse_stmt` / `parse_select_core` / `parse_expr`
  now accept a `model.Engine` argument. `InsertStmt` grows an
  `on_duplicate_key_update: List(Assignment)` field so MySQL
  `ON DUPLICATE KEY UPDATE` survives parsing as first-class IR instead
  of being silently skipped. MySQL's two-argument `LIMIT offset, count`
  form is now recognised and populates `offset` / `limit` in the
  expected order, while PostgreSQL's `LIMIT count OFFSET offset`
  semantics are preserved.
- **First-class MySQL `ENUM(...)` and `SET(...)` columns** (#407).
  Inline `ENUM` and `SET` column types on a MySQL `CREATE TABLE` no
  longer require a type override. `EnumDef` gains an `EnumKind`
  discriminator (`PostgresEnum | MySqlEnum | MySqlSet`). `ENUM`
  columns resolve to `EnumType(<table>_<column>)` and codegen emits
  the same Gleam sum type it has always emitted for PostgreSQL enums.
  `SET` columns resolve to `StringType` as a documented fallback,
  with the allowed values preserved on the catalog `EnumDef` for
  future consumers.
- **`sqlode init` creates missing parent directories** (#402). Running
  `sqlode init --output=./config/sqlode.yaml` used to fail with a
  generic write error when `config/` did not exist; the CLI now
  creates the parent directory and distinguishes directory-creation
  failures from file-write failures in diagnostics.
- **`just regen-capabilities` target** (#403). The capabilities
  snapshot test used to point contributors at a `gleam run -m
  sqlode/scripts/print_capabilities` entry point that did not exist;
  the script and just target are now real, and the failure message
  plus the tracked file header point at `just regen-capabilities`.

### Changed

- **Query analysis now consumes the expression-aware IR end-to-end**
  (#406). `analyze_query` parses the statement once via
  `expr_parser.parse_stmt` and drives parameter equality / `IN` /
  quantified inference from the rich `Expr` tree, plus table-scope
  (CTE / VALUES / derived / alias) extraction from `Stmt.ctes` and
  `SelectCore.from`. Token scanners remain as an explicit fallback
  only for `UnstructuredStmt` and for PostgreSQL / SQLite `ON
  CONFLICT` tails the IR does not yet model. Result: new parser
  features no longer need to be taught in parallel to several
  token scanners.
- **Generated-project compile checks are reproducible** (#404). The
  `spec/compile_spec.sh` harness now seeds each temporary Gleam
  project with a pinned `manifest.toml` copied from a checked-in
  `integration_test/warmup/` project. A new `just integration-prepare`
  target pre-populates the Hex cache and is the single explicit
  online step `just all` requires; `just integration-refresh` refreshes
  the committed pins. `CONTRIBUTING.md` documents the online/offline
  contract.

### Fixed

- None.

## [0.3.0] - 2026-04-18

### Added

- **`sqlode verify` command**: A static verification lane that walks
  every SQL block listed in the config, runs the full schema /
  strict-views / query / analyzer pipeline, and reports every finding
  without writing files. Exits non-zero when any finding is present,
  suitable as a CI gate before `sqlode generate`. The new
  `query_parameter_limit` config option (mirroring sqlc's setting of
  the same name) becomes the first enforced policy — queries whose
  inferred parameter count exceeds the limit produce a finding.
- **Function-first `prepare_<query>` helpers**: Every generated query
  now emits a `prepare_<function_name>(...)` helper that takes the
  params record fields as positional arguments and returns the
  `#(sql, values)` tuple Gleam database drivers consume directly.
  Call sites can now use `queries.prepare_get_author(id: 1)` instead
  of manually composing a query descriptor, a params record, and
  `runtime.prepare`. The low-level descriptor API is preserved for
  batching, caching, or custom wrappers.
- **Expression-aware SQL IR**: Replaced the thin statement IR with a
  normalised IR (`Stmt` / `SelectCore` / `CteDef` / `Expr`) covering
  CTEs, LATERAL, select items, predicates, arithmetic, CASE,
  functions, casts, `IN`, `EXISTS`, `ANY` / `ALL`, window specs, and
  RETURNING. Type inference now operates on the IR instead of
  reverse-engineering semantics from raw token slices, and
  `col = ANY(placeholder)` / sibling quantified patterns now
  participate in parameter inference alongside `IN`. LATERAL subquery
  aliases are treated as nullable when the surrounding join is
  `LEFT [OUTER] JOIN LATERAL`. Four executable fixtures under
  `test/fixtures/complex_sql_*.sql` pin the new behaviour.

### Changed

- **`strict_views: true` is now the default**. A configuration that
  omits `strict_views` previously warned and continued with a partial
  catalog, letting a generated model silently drift away from the
  real database shape. Generation now fails with a `SchemaParseError`
  when a view references an unknown column. Set `strict_views: false`
  to restore the legacy permissive behaviour for schemas that still
  need it.
- RETURNING resolution is now scoped to the DML target table, so
  `INSERT .. SELECT .. RETURNING` no longer sees CTE / SELECT source
  tables as ambiguous candidates.
- The schema parser now accepts non-reserved keywords (`action`,
  `name`, `order`, …) as column identifiers.

### Fixed

- **Ambiguous unqualified parameter columns are now rejected.**
  Parameter inference previously swallowed ambiguity from
  `context.find_column_in_tables` and fell back to the primary
  table, so `WHERE id = $1` in a multi-table query silently bound the
  param type to whichever table came first. Unqualified predicate
  columns that match more than one in-scope table now raise
  `AmbiguousColumnName`. The token scan's FROM scope is also
  restricted to the outermost statement via
  `token_utils.strip_leading_with`, so CTE-internal tables no longer
  leak into the ambiguity check for the outer predicate.

## [0.2.1] - 2026-04-18

### Fixed

- Raw decoder for embedded columns (e.g., `sqlode.embed(table)`) now
  correctly constructs the nested type (e.g., `Author(id:, name:, bio:)`)
  instead of flattening all fields into the outer row constructor.

## [0.2.0] - 2026-04-18

### Added

- **Destructive DDL support**: The schema parser now applies `DROP TABLE`,
  `DROP VIEW`, `DROP TYPE`, `ALTER TABLE ... DROP COLUMN`,
  `ALTER TABLE ... RENAME TO` / `RENAME COLUMN`,
  `ALTER TABLE ... ALTER COLUMN TYPE` / `SET NOT NULL` / `DROP NOT NULL`
  to the catalog. Full migration histories with destructive DDL can now
  be processed without consolidating into a snapshot.
- **Ambiguous column detection**: `find_column_in_tables` now errors when
  a bare column name matches in two or more tables, instead of silently
  picking the first match. Use a table qualifier (e.g., `table.column`)
  to resolve the ambiguity.
- **IR-based column inference**: The column inferencer now uses the
  structured IR (`SelectStatement.select_items`, `from`, `joins`) for
  simple SELECT queries, reducing reliance on token-level heuristics.
  Compound queries (UNION/EXCEPT) and `sqlode.embed()` fall back to the
  existing token-based path.
- **Raw decoder generation**: `queries.gleam` now generates standalone
  `*_decoder()` functions for `:one` / `:many` queries in raw mode,
  providing type-safe `decode.Decoder(models.Row)` values without
  requiring a native adapter.

### Fixed

- `sqlode.embed(TABLE)` is now rewritten into a concrete qualified
  column list in the emitted SQL. Previously the literal
  `sqlode.embed(...)` text leaked into generated runtime queries, which
  the database rejected as invalid SQL. Embed detection during column
  inference is also now case-insensitive.
- Table qualifier in `table.column` patterns was silently discarded in
  `resolve_column_type_from_tokens` and
  `resolve_column_type_nullable_from_tokens`, causing lookups to search
  all tables instead of the specified one.
- `sqlc-compatibility.md` incorrectly stated that batch annotations and
  `sqlc.*` prefix were implemented. Updated to reflect actual status.

### Changed

- `UnsupportedStatement` schema parse error removed. Destructive DDL
  statements are now applied rather than rejected.
- README updated to clarify that sqlode is not a drop-in sqlc
  replacement and uses the `sqlode.*` macro prefix exclusively.

## [0.1.0] - 2026-04-13

### Added

- Initial sqlc-style code generator for Gleam
- PostgreSQL, MySQL, and SQLite engine support
- Query annotations `:one`, `:many`, `:exec`, `:execresult`, `:execrows`, `:execlastid` supported end-to-end. `:batchone`, `:batchmany`, `:batchexec`, and `:copyfrom` are parsed for sqlc compatibility but currently fail generation with an unsupported-annotation error.
- sqlode macros: `sqlode.arg`, `sqlode.narg`, `sqlode.slice`, `sqlode.embed`
- Type mapping for INT, FLOAT, BOOL, TEXT, BYTEA, UUID, JSON, TIMESTAMP, DATE, TIME
- PostgreSQL ENUM type support
- Nullable column detection with `Option(T)` wrapping
- Result record types (`models.gleam`) for `:one` and `:many` queries
- Adapter generation for pog (PostgreSQL) and sqlight (SQLite)
- RETURNING clause support for INSERT/UPDATE/DELETE
- CTE (WITH clause) support
- JOIN type inference
- Type overrides and column renames via config
- `init` command with stub `db/schema.sql` and `db/query.sql` creation
- `generate` command with `--config` flag
- Version constant in `version.gleam` as single source of truth
