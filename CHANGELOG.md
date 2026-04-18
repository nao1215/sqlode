# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
