# sqlode capability manifest

This file is generated from `src/sqlode/capabilities.gleam` and
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

These annotations exist in sqlc and are still parseable in
`.sql` files, but sqlode currently refuses to emit code for
them. See `validate_unsupported_annotations` in `generate.gleam`.

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
