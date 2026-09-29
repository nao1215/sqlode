# Error reference

Every error sqlode prints starts with a code, such as `Error: SQD4003: Query "GetAuthor": could not infer type for parameter $1. ...`, and `verify` findings carry the same codes: `[src/db] SQD4003: ...`. Match on the code, not on the wording: a code keeps its meaning across releases, while messages may be reworded.

The first digit names the area. It is not the exit code: every error exits 1.

| Codes | Area |
|---|---|
| SQD1xxx | Command line and config |
| SQD2xxx | Schema files |
| SQD3xxx | Query files |
| SQD4xxx | Query analysis |
| SQD5xxx | Output |

Warnings (a view column that cannot be resolved, a custom type without codec hooks, `gleam format` failing on the generated files) carry no code and do not change the exit status.

## SQD1001

No subcommand was given (`sqlode` alone). Run `sqlode generate`, `sqlode verify`, `sqlode init` or `sqlode version`.

## SQD1002

The first argument is not a subcommand sqlode knows. Check the spelling; `sqlode --help` lists the subcommands.

## SQD1003

An option was given before any subcommand (`sqlode --config=x generate`). Put the subcommand first: `sqlode generate --config=x`.

## SQD1004

A flag or its value was not accepted: the flag does not exist for this subcommand, or it has no value (`--config` at the end of the line). The help text printed after the error lists the flags. Both `--config=path` and `--config path` work.

## SQD1005

`sqlode init` got an engine other than `postgresql`, `sqlite` or `mysql`, or a runtime other than `raw` or `native`.

## SQD1006

`sqlode init` does not overwrite an existing config. Remove the file, or pass another path with `--output`.

## SQD1007

`sqlode init` could not create the config's directory or write a file into it. The message names the path and the reason from the file system.

## SQD1101

`generate` or `verify` found no config in the current directory. It looks for `sqlode.yaml`, `sqlode.yml`, `sqlc.yaml`, `sqlc.yml` and `sqlc.json`. Run `sqlode init`, or pass `--config=<path>`.

## SQD1102

More than one config candidate is in the current directory, so sqlode does not guess. Pass `--config=<path>`, or remove the one you do not use.

## SQD1103

The file given with `--config` does not exist. Paths are relative to the current directory.

## SQD1104

The config exists but could not be read, usually because of its permissions.

## SQD1105

The config is not valid YAML. The message carries the parser's description.

## SQD1106

A required key is missing: `version`, `sql`, or in each `sql` block `schema`, `queries`, `engine` or `gen.gleam.out`. Compare with the config `sqlode init` writes.

## SQD1107

A key has a value sqlode does not accept, such as an unknown `engine` or `runtime`, or a string where a list is expected. The message names the key and the accepted values.

## SQD1108

The config uses keys sqlode does not support, typically sqlc options for other languages. Remove them; the message lists the keys sqlode reads.

## SQD2001

A `schema` path could not be read: it does not exist, is not readable, or is a directory without `.sql` files. Paths in the config are relative to the config file.

## SQD2002

A `CREATE TABLE` statement could not be parsed. The message names the file and what was expected.

## SQD2003

A column definition inside `CREATE TABLE` could not be parsed. The message names the table and the column text.

## SQD2004

A MySQL schema contains a DDL statement sqlode does not understand. sqlode stops instead of skipping it, so no table or column goes missing silently. Move the statement out of the files listed under `schema`, or open an issue with the statement.

## SQD2005

`strict_views: true` is set and a view column could not be resolved from its source tables. The message lists the columns. Fix the view, or turn `strict_views` off to keep the warning without failing.

## SQD3001

A `queries` path could not be read: it does not exist, is not readable, or is a directory without `.sql` files. Paths in the config are relative to the config file.

## SQD3002

A `-- name:` annotation is malformed. The form is `-- name: QueryName :one` with one of `:one`, `:many`, `:exec`, `:execrows`, `:execlastid`, `:execresult`.

## SQD3003

An annotation is followed by no SQL before the next annotation or the end of the file.

## SQD3004

A placeholder does not belong to the configured engine: PostgreSQL takes `$N`, MySQL takes `?`, and SQLite takes `?`, `?N`, `:name`, `@name` or `$name`. `sqlode.arg(name)` works everywhere.

## SQD3005

An upsert uses another engine's syntax. PostgreSQL and SQLite take `ON CONFLICT ... DO UPDATE` / `DO NOTHING`; MySQL takes `ON DUPLICATE KEY UPDATE`.

## SQD3006

SQLite numbered placeholders skip a number (`?1`, `?3`). Number them from `?1` without gaps, since each number becomes one parameter.

## SQD3007

Two queries have the same name. Every `-- name:` in a `sql` block must be unique, across all its query files.

## SQD3008

Different query names turn into the same Gleam identifier (`GetUser` and `get_user`). Rename one of them.

## SQD4001

A query reads a table the schema does not define. Check the spelling, and that the file with its `CREATE TABLE` is listed under `schema`.

## SQD4002

A query names a column the table does not have. Check the spelling, and whether a migration renamed or dropped it.

## SQD4003

sqlode could not tell a parameter's type from where it appears. It infers a type from `col = $1` and other comparisons, `col IN (...)`, `ANY`, arithmetic with a numeric column, `INSERT ... VALUES`, `SET col = $1`, `LIMIT` and `OFFSET`. Anywhere else, cast the parameter: `$1::int` in PostgreSQL, `CAST(? AS INTEGER)` in SQLite, `CAST(? AS SIGNED)` in MySQL.

## SQD4004

One parameter is used in two places that imply different types, such as `id = $1 AND name = $1`. Use two parameters, or cast it to the type you mean.

## SQD4005

A cast on a parameter names a type sqlode does not map to a Gleam type. Use a type name the schema parser also accepts in column definitions (`int`, `bigint`, `text`, `boolean`, `numeric`, `timestamp`, ...).

## SQD4006

The branches of a `UNION`, `INTERSECT` or `EXCEPT` select different numbers of columns. Every branch must select the same number.

## SQD4007

sqlode cannot tell the type of an expression in the select list, such as a function it does not know. Cast the expression, `CAST(expr AS type)`, and give it a name with `AS`.

## SQD4008

A column name exists in more than one joined table, so the reference is ambiguous. Qualify it with the table or alias: `a.id` instead of `id`.

## SQD4009

The annotation is not supported: `:batchone`, `:batchmany`, `:batchexec` and `:copyfrom` in general, and `:execresult` with `runtime: native`. The message names the annotation to use instead. `-- sqlode:skip` before the annotation leaves the query out of generation.

## SQD4010

A query takes an array parameter (`col = ANY($1)`, `$1::int[]`), and the engine is SQLite or MySQL, which have no array parameters. Use `col IN (sqlode.slice(ids))`, which expands to one placeholder per element.

## SQD4011

`sqlode.slice(...)` is used inside `ANY`, `ALL` or `SOME`. A slice expands to one placeholder per element, and `ANY` takes a single array, so the query can never run. Write `col IN (sqlode.slice(ids))`, or pass one array parameter with `col = ANY($1)` on PostgreSQL.

## SQD4012

`verify` only: a query has more parameters than `query_parameter_limit` allows for its `sql` block. Split the query, or raise the limit.

## SQD5001

A `sql` block produced no queries: its query files contain no `-- name:` annotations, or every query was skipped. The message says how many queries and tables were found.

## SQD5002

`gen.gleam.out` does not make a valid Gleam module path. Use a relative path under `src/`, such as `src/db`.

## SQD5003

A generated file or its directory could not be written. The message names the path.

## SQD5004

`vendor_runtime: true` is set, but the `sqlode/runtime` source to copy was not found. Add sqlode as a dependency (`gleam add sqlode`) so its source is under `build/packages`, or turn `vendor_runtime` off.
