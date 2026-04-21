# Getting started with sqlode and SQLite

This tutorial walks you from an empty directory to a typed,
compile-checked SQLite data layer in about five minutes. It targets
the `sqlight` native runtime so the generated adapter opens a real
SQLite connection; no schema changes in a separate migration tool are
required.

A ready-made version of every file in this tutorial lives under
[`examples/sqlite-basic/`](../../examples/sqlite-basic/). You can copy
that directory and skip ahead to [Run the generator](#3-run-the-generator)
if you prefer.

## Prerequisites

- Erlang/OTP 27 or later with `escript` on `PATH`
- Gleam 1.10 or later
- A POSIX shell (Linux, macOS, or WSL)

## 1. Install sqlode

The fastest path is the published release escript:

```console
curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
```

The installer writes `sqlode` to `$HOME/.local/bin/sqlode`. Make sure
that directory is on your `PATH`.

If you prefer to invoke sqlode through your project's deps instead,
you can replace every `sqlode` command below with
`gleam run -m sqlode --`.

## 2. Scaffold a project

```console
gleam new hello_sqlode
cd hello_sqlode
gleam add sqlight
gleam add sqlode
sqlode init --engine=sqlite --runtime=native
```

`sqlode init` creates:

- `sqlode.yaml` — generator config pointed at `db/schema.sql` and
  `db/query.sql`
- `db/schema.sql` — a starter `authors` table
- `db/query.sql` — `GetAuthor`, `ListAuthors`, and `CreateAuthor`
  queries

Open `db/schema.sql` and `db/query.sql` to see what a minimal sqlode
project looks like. You can edit these freely — the next step
regenerates the Gleam code.

## 3. Run the generator

```console
sqlode generate
```

This writes four modules under `src/db/`:

| File                    | What it holds                                    |
| ----------------------- | ------------------------------------------------ |
| `params.gleam`          | Typed parameter records (one per query)          |
| `models.gleam`          | Row structs for `:one` / `:many` results         |
| `queries.gleam`         | Query descriptors and `prepare_*` helpers        |
| `sqlight_adapter.gleam` | High-level functions that run the queries on a `sqlight.Connection` |

Every regeneration is idempotent — rerun it whenever you touch
`db/schema.sql` or `db/query.sql`.

## 4. Use the adapter

Replace `src/hello_sqlode.gleam` with:

```gleam
import db/params
import db/sqlight_adapter
import gleam/io
import gleam/option
import sqlight

pub fn main() {
  let assert Ok(db) = sqlight.open(":memory:")

  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        bio TEXT
      );",
      db,
    )

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("A bio")),
    )

  let assert Ok(option.Some(author)) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))
  io.println("Loaded author: " <> author.name)
}
```

Then run:

```console
gleam run
```

Expected output:

```
Loaded author: Alice
```

## 5. Iterate

Any time you edit SQL:

1. Update `db/schema.sql` or `db/query.sql`.
2. Run `sqlode generate`.
3. The Gleam compiler tells you about every call site that now has
   the wrong parameter or return shape — that is the whole point.

To keep your CI in sync, run `sqlode verify` as a fast preflight:

```console
sqlode verify
```

## Where to look next

- [`examples/sqlite-basic/`](../../examples/sqlite-basic/) — the
  finished version of this tutorial, used by the repository's smoke
  test so this walkthrough stays current.
- [`doc/capabilities.md`](../capabilities.md) — full engine/runtime
  support matrix.
- [`README.md`](../../README.md) — the reference-oriented entry
  point once you have finished the tutorial.
