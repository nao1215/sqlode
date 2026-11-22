# sqlode capability manifest

This file is generated from `src/sqlode/internal/capabilities.gleam` and
verified by `test/capabilities_test.gleam`. Do not edit by hand;
update the capabilities module and run `just regen-capabilities`.

## Engines

- `postgresql`
- `mysql`
- `sqlite`

## Runtimes

- `raw`
- `native`

## Engine / runtime support

| Engine | Raw | Native | Native driver |
| --- | --- | --- | --- |
| `postgresql` | yes | yes | `pog` |
| `mysql` | yes | yes | `shork` |
| `sqlite` | yes | yes | `sqlight` |

## Type mappings

- `string`
- `rich`
- `strong`

## Query annotations

### Fully supported

- `:one`
- `:many`
- `:exec`
- `:execresult`
- `:execrows`
- `:execlastid`

### Parsed but rejected at generation time

sqlc has these annotations. sqlode reads them and stops generation
with an error.

- `:batchone`
- `:batchmany`
- `:batchexec`
- `:copyfrom`

## Macros

- `sqlode.arg(...)`
- `sqlode.narg(...)`
- `sqlode.slice(...)`
- `sqlode.embed(...)`

## Placeholder styles

- `postgresql` → `runtime.DollarNumbered`
- `mysql` → `runtime.QuestionPositional`
- `sqlite` → `runtime.QuestionNumbered`
