# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
