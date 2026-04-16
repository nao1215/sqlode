# Related OSS

This is a shortlist of projects that are worth reading while designing
or implementing `sqlode`.

## Core references

| Project | License | Why it matters | What to borrow |
| --- | --- | --- | --- |
| [sqlc](https://github.com/sqlc-dev/sqlc) | MIT | Canonical UX and behavior target | config shape, query annotations, nullability expectations, generated API ergonomics |
| [TiDB parser](https://pkg.go.dev/github.com/pingcap/tidb/pkg/parser) | Apache-2.0 | MySQL-compatible parser reference; sqlc is listed as a user | grammar coverage, AST boundaries, MySQL regression cases |
| [parrot](https://hexdocs.pm/parrot/) | package docs; see project repo for source license | Existing Gleam + sqlc-inspired project already covering MySQL/PostgreSQL/SQLite | Gleam-facing API shape, wrapper ergonomics, runtime adapter ideas |
| `nao1215/oaspec` | local repo reference | Same author's Gleam code generator with strong CLI + test discipline | CI order, ShellSpec organization, compile-the-generated-code integration tests |

## Candidate Gleam runtime libraries

| Project | License | Engine | Why it matters |
| --- | --- | --- | --- |
| [pog](https://hex.pm/packages/pog) | Apache-2.0 | PostgreSQL | strong candidate for a first-party PostgreSQL adapter |
| [sqlight](https://hex.pm/packages/sqlight) | Apache-2.0 | SQLite | strong candidate for a first-party SQLite adapter |
| [gmysql](https://hex.pm/packages/gmysql) | Apache-2.0 | MySQL | strongest MySQL-side adapter candidate found in Gleam ecosystem |
| [based](https://hex.pm/packages/based) | Apache-2.0 | abstraction | common interface for adapters; reduces generator lock-in |
| [based_pg](https://hex.pm/packages/based_pg) | Apache-2.0 | PostgreSQL | reference adapter on top of `based` |
| [based_sqlite](https://hex.pm/packages/based_sqlite) | Apache-2.0 | SQLite | reference adapter on top of `based` |

## Design takeaways

sqlc is the behavior oracle for config parsing and query annotation
semantics. Its Go-specific API choices (batch APIs, driver model) should
not be copied into Gleam without adaptation.

TiDB parser is useful as a MySQL compatibility map. Its documentation
covers almost all MySQL features and uses goyacc-based parser
generation, but it should not be treated as authoritative for PostgreSQL
or SQLite semantics.

parrot matters because sqlc lists it as the community Gleam project
covering all three engines. It is a good comparison point for user
expectations, generated function shapes, and adapter strategy around
`pog` / `sqlight`.

From oaspec, the test philosophy is worth borrowing: small Gleam unit
tests for internal modules, ShellSpec tests for CLI output and generated
files, integration scripts that compile a fresh generated project, and
CI ordering that fails early on format / check / build.

## Pitfalls

Avoid vendoring large upstream codebases into sqlode. Keep the runtime
adapter layer decoupled from any single Gleam DB library. Do not rely on
TiDB parser behavior when targeting PostgreSQL or SQLite.

## Sources

- sqlc GitHub:
  https://github.com/sqlc-dev/sqlc
- sqlc language support:
  https://docs.sqlc.dev/en/stable/reference/language-support.html
- TiDB parser package:
  https://pkg.go.dev/github.com/pingcap/tidb/pkg/parser
- TiDB MySQL compatibility:
  https://docs.pingcap.com/tidbcloud/mysql-compatibility/
- parrot docs:
  https://hexdocs.pm/parrot/
- pog:
  https://hex.pm/packages/pog
- sqlight:
  https://hex.pm/packages/sqlight
- gmysql:
  https://hex.pm/packages/gmysql
- based:
  https://hex.pm/packages/based
- based_pg:
  https://hex.pm/packages/based_pg
- based_sqlite:
  https://hex.pm/packages/based_sqlite
- local `oaspec` references:
  - `/home/nao/ghq/github.com/nao1215/oaspec/.github/workflows/ci.yml`
  - `/home/nao/ghq/github.com/nao1215/oaspec/spec/generate_spec.sh`
  - `/home/nao/ghq/github.com/nao1215/oaspec/spec/spec_helper.sh`
  - `/home/nao/ghq/github.com/nao1215/oaspec/integration_test/run.sh`
