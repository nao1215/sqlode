# sqlode Architecture

## Product definition

`sqlode` is a sqlc-like compiler that reads SQL schema/query files and
generates typed Gleam code.

The compatibility target is:

- sqlc-like configuration and query annotation syntax
- Gleam-native generated modules
- PostgreSQL, MySQL (parsing only), and SQLite support

## Top-level architecture

The pipeline has four stages:

1. config loading
2. SQL parsing (schema + query)
3. query analysis
4. Gleam code generation

## 1. Config loading (`config.gleam`)

Responsibilities:

- parse sqlc-style config v2 from YAML
- resolve schema/query file paths (string or list)
- validate engine and runtime values
- parse overrides (type overrides and column renames)
- produce precise diagnostics via `ConfigError` variants

## 2. SQL parsing

### Schema parsing (`schema_parser.gleam`)

A single unified parser handles all SQL dialects:

- parses `CREATE TABLE` statements into `Catalog` (tables + columns)
- parses `CREATE TYPE ... AS ENUM` for PostgreSQL enums
- infers scalar types from SQL type names via data-driven lookup
- handles `IF NOT EXISTS`, quoted identifiers, table constraints
- normalizes identifiers via shared `naming.normalize_identifier`

### Query parsing (`query_parser.gleam`)

A single unified parser handles all SQL dialects:

- parses `-- name: <Name> <command>` annotations
- counts placeholders per engine (`$N` for PostgreSQL, `?` for MySQL,
  `?N`/`:name`/`@name`/`$name` for SQLite)
- expands `sqlode.arg`, `sqlode.narg`, `sqlode.slice` macros into
  engine-agnostic markers (`__sqlode_param_N__`, `__sqlode_slice_N__`)
  that `runtime.prepare` substitutes with engine-specific placeholders

## 3. Query analysis (`query_analyzer.gleam`)

Analyzes parsed queries against the schema catalog:

- infers parameter types from INSERT column order and WHERE equality
- infers result columns from SELECT lists, `*` expansion, table prefixes
- resolves JOIN tables and `sqlode.embed` table expansion
- handles RETURNING clauses and CTE (WITH) stripping
- detects conflicting type inferences for the same placeholder

## 4. Gleam code generation (`codegen/`)

Generates Gleam source files from analyzed queries:

### Generated files

- `params.gleam` — parameter record types and value conversion functions
- `queries.gleam` — query metadata (name, SQL, command, param count)
- `models.gleam` — result row types (only when queries return rows)
- `<engine>_adapter.gleam` — database adapter functions (when runtime
  is `native`)

### Adapter generation

Uses `AdapterConfig` record to parameterize engine-specific differences:

- `pog_adapter.gleam` for PostgreSQL (pog library)
- `sqlight_adapter.gleam` for SQLite (sqlight library)
- MySQL adapter is a stub (no driver available)

Shared `render_adapter_*` functions dispatch through config callbacks for
library imports, connection types, parameter encoding, and query call
patterns.

## Module overview

```text
src/sqlode/
  cli.gleam              — CLI commands (generate, init, version)
  query_ir.gleam         — intermediate representation (TokenizedQuery)
  config.gleam           — YAML config parsing
  generate.gleam         — orchestrates the pipeline
  lexer.gleam            — SQL tokenizer for all dialects
  model.gleam            — shared types (Engine, Config, Query, ScalarType, etc.)
  naming.gleam           — NamingContext, identifier normalization, case conversion
  query_analyzer.gleam   — top-level query analysis orchestrator
  query_parser.gleam     — query annotation parsing with ParserContext
  schema_parser.gleam    — DDL schema parsing
  runtime.gleam          — runtime types (Value, QueryCommand)
  version.gleam          — version constant
  writer.gleam           — file output

  query_analyzer/
    column_inferencer.gleam — result column inference
    context.gleam           — AnalyzerContext, AnalysisError, catalog lookups
    param_inferencer.gleam  — parameter type inference
    placeholder.gleam       — placeholder extraction and indexing
    token_utils.gleam       — SQL token helpers (table name extraction, etc.)

  codegen/
    adapter.gleam  — database adapter generation (pog, sqlight)
    common.gleam   — shared codegen utilities
    models.gleam   — result row type generation
    params.gleam   — parameter type generation
    queries.gleam  — query metadata generation
```

## IR types (`model.gleam`)

The IR consumed by codegen:

- `Config`, `SqlBlock`, `GleamOutput`, `Overrides`
- `Catalog`, `Table`, `Column`, `EnumDef`
- `ParsedQuery`, `QueryCommand`, `Macro`
- `AnalyzedQuery`, `QueryParam`, `ResultColumn`
- `ScalarType` — IntType, FloatType, BoolType, StringType, BytesType,
  DateTimeType, DateType, TimeType, UuidType, JsonType, EnumType,
  CustomType(name, module, underlying), ArrayType(element)

## Runtime strategy

A single flat `runtime.gleam` module exports:

- `QueryCommand` type (QueryOne, QueryMany, QueryExec, etc.)
- `Value` type (SqlNull, SqlString, SqlInt, SqlFloat, SqlBool, SqlBytes, SqlArray)
- Constructor functions (`null`, `string`, `int`, `float`, `bool`, `bytes`, `array`, `nullable`)
- `prepare` function that substitutes engine-agnostic markers with
  engine-specific placeholders and expands slice parameters

### `gen.gleam.runtime` values

- `raw` — generates only params, queries, models (no adapter)
- `native` — generates adapter module for pog (PostgreSQL) or sqlight (SQLite)

`based` is rejected at config validation.

## Implementation status

### Completed

- Config parsing with overrides and column renames
- All 10 query annotations (`:one`, `:many`, `:exec`, `:execresult`, `:execrows`, `:execlastid`, `:batchone`, `:batchmany`, `:batchexec`, `:copyfrom`)
- All sqlode macros (`sqlode.arg`, `sqlode.narg`, `sqlode.slice`, `sqlode.embed`)
- Comprehensive type mapping (integers, floats, booleans, strings, bytes,
  date/time/timestamp, UUID, JSON/JSONB, PostgreSQL enums, PostgreSQL arrays)
- Nullable detection and `Option(T)` wrapping
- JOIN type inference, RETURNING clause, CTE support
- pog and sqlight adapter generation
- `init` command with stub file creation

### Not yet implemented

- `database` / `analyzer` config fields for live DB analysis
- `query_parameter_limit`
- MySQL native adapter (no Gleam MySQL driver exists)
- Golden-file / snapshot testing for codegen output
