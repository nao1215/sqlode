# sqlite-basic

A minimal runnable sqlode example that targets SQLite with the
native `sqlight` adapter.

The full walkthrough lives in
[`doc/tutorials/getting-started-sqlite.md`](../../doc/tutorials/getting-started-sqlite.md).

## Layout

```
examples/sqlite-basic/
├── sqlode.yaml          # engine=sqlite, runtime=native, out=src/db
├── db/
│   ├── schema.sql       # authors table
│   └── query.sql        # GetAuthor / ListAuthors / CreateAuthor / DeleteAuthor
├── src/
│   └── sqlite_basic.gleam
└── test/
    └── sqlite_basic_test.gleam
```

`src/db/` is intentionally absent from the repository. Running
`sqlode generate` in this directory writes
`params.gleam`, `models.gleam`, `queries.gleam`, and
`sqlight_adapter.gleam` under `src/db/`, which the test module imports.

## Run

```console
cd examples/sqlite-basic
gleam deps download
sqlode generate --config=sqlode.yaml   # or: gleam run -m sqlode -- generate
gleam test
```
