# sqlode

[![CI](https://github.com/nao1215/sqlode/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/sqlode/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/sqlode/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/sqlode/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/osv-scan.yml)
[![tested with atago](https://img.shields.io/badge/tested%20with-atago-7c3aed?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0iI2ZmZiIgZD0iTTMuNiA0LjIgMTEuOSAxMmwtOC4zIDcuOC0xLjktMi4yTDcuOSAxMiAxLjcgNi40eiIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjEyLjYiIHk9IjE3LjIiIHdpZHRoPSI5LjciIGhlaWdodD0iMi44IiByeD0iMS40Ii8%2BPC9zdmc%2B&logoColor=white)](https://github.com/nao1215/atago)
[![measured with himorime](https://img.shields.io/badge/measured%20with-himorime-d9480f?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZmZmIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBkPSJNNC4yIDE4LjVBOSA5IDAgMSAxIDE5LjggMTguNSIvPjxwYXRoIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgZD0iTTEyIDE0LjUgMTYuNSA5Ii8%2BPGNpcmNsZSBmaWxsPSIjZmZmIiBjeD0iMTIiIGN5PSIxNC41IiByPSIyLjIiLz48L3N2Zz4=&logoColor=white)](https://github.com/nao1215/himorime)
[![Hex](https://img.shields.io/hexpm/v/sqlode)](https://hex.pm/packages/sqlode)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/sqlode/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/sqlode)](https://hex.pm/packages/sqlode)
[![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/nao1215/sqlode/total)](https://github.com/nao1215/sqlode/releases)
[![License](https://img.shields.io/github/license/nao1215/sqlode)](https://github.com/nao1215/sqlode/blob/main/LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/sqlode/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/sqlode)

sqlode reads SQL schema and query files and generates typed Gleam code: write SQL, run the generator, call the generated functions. The workflow follows [sqlc](https://sqlc.dev/), and sqlode reads an existing `sqlc.yaml`, but its macros use the `sqlode.*` prefix.

It supports PostgreSQL ([pog](https://hexdocs.pm/pog/)), MySQL 8.0 ([shork](https://hexdocs.pm/shork/)) and SQLite ([sqlight](https://hexdocs.pm/sqlight/)).

## Quickstart

```console
gleam new myapp
cd myapp
gleam add sqlode sqlight
gleam run -m sqlode -- init --engine=sqlite --runtime=native
```

`init` writes `db/schema.sql`, `db/query.sql` and this `sqlode.yaml`:

```yaml
version: "2"
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "sqlite"
    gen:
      gleam:
        out: "src/db"
        runtime: "native"
```

Put your schema and queries in the two SQL files:

```sql
-- db/schema.sql
CREATE TABLE authors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  bio TEXT
);

-- db/query.sql
-- name: GetAuthor :one
SELECT id, name, bio FROM authors WHERE id = ?;

-- name: ListAuthors :many
SELECT id, name FROM authors ORDER BY name;

-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES (sqlode.arg(name), sqlode.narg(bio));
```

```console
$ gleam run -m sqlode -- generate
Loading config from: sqlode.yaml

Successfully generated 4 files
  Generated: src/db/params.gleam
  Generated: src/db/queries.gleam
  Generated: src/db/models.gleam
  Generated: src/db/sqlight_adapter.gleam
  Formatted generated code
```

The adapter binds parameters, runs the query and decodes the rows:

```gleam
import db/params
import db/sqlight_adapter
import gleam/io
import gleam/option.{Some}
import sqlight

pub fn main() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, bio TEXT);",
      db,
    )

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Poet")),
    )
  let assert Ok(Some(author)) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))
  io.println(author.name)
  // -> Alice
}
```

With `runtime: "raw"` (the default) sqlode skips the adapter: `queries.prepare_get_author(id: 1)` returns the SQL and the parameter values for any driver, and `queries.get_author_decoder()` decodes a row. [`examples/sqlite-basic`](https://github.com/nao1215/sqlode/tree/main/examples/sqlite-basic) is a runnable project.

## Writing queries

- Each query starts with `-- name: Name :command`, where the command is `:one`, `:many`, `:exec`, `:execrows`, `:execlastid` or `:execresult` (raw only).
- `sqlode.arg(name)` and `sqlode.narg(name)` name a parameter and a nullable parameter. `@name` is a shorthand on PostgreSQL and SQLite.
- `IN (sqlode.slice(ids))` takes a `List` and binds one placeholder per element. An empty list matches no rows.
- `SELECT sqlode.embed(authors), books.title` returns the table's columns as one nested `Author` field.
- `-- sqlode:skip` before the annotation leaves a query out of generation.

Parameter and column types come from the schema. Where sqlode cannot infer a parameter type, add a cast such as `$1::int`. The [capabilities](https://hexdocs.pm/sqlode/capabilities.html) page lists every engine, annotation and macro, and [configuration](https://hexdocs.pm/sqlode/configuration.html) covers type overrides, the type mapping and the YAML keys.

## Command line

```console
sqlode init     [--output=sqlode.yaml] [--engine=postgresql|sqlite|mysql] [--runtime=raw|native]
sqlode generate [--config=sqlode.yaml]
sqlode verify   [--config=sqlode.yaml]
sqlode version
```

`verify` checks the project like `generate` without writing files and reports every problem. Errors start with a stable code such as `SQD4003`, explained on the [errors](https://hexdocs.pm/sqlode/errors.html) page.

The command runs as `gleam run -m sqlode --`, as a standalone escript from [GitHub Releases](https://github.com/nao1215/sqlode/releases) (needs Erlang/OTP), or with Docker:

```console
curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
docker run --rm -v "$PWD:/work" ghcr.io/nao1215/sqlode:latest generate
```

Generated code imports `sqlode/runtime`, so keep sqlode as a regular dependency, or set `vendor_runtime: true` to copy the runtime into the output directory.

## Verifying releases

Each release carries `SHA256SUMS` for the escript, its CycloneDX SBOM and the bundled third-party licenses, with a cosign keyless signature and SLSA provenance. With the release files in the current directory:

```console
sha256sum -c SHA256SUMS
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/nao1215/sqlode/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
gh attestation verify sqlode --repo nao1215/sqlode
```

The Docker image is signed by digest: `cosign verify ghcr.io/nao1215/sqlode:0.35.0 --certificate-identity-regexp '^https://github.com/nao1215/sqlode/' --certificate-oidc-issuer https://token.actions.githubusercontent.com`.

## License

[MIT](https://github.com/nao1215/sqlode/blob/main/LICENSE)
