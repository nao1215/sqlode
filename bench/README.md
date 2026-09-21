# Benchmarks

sqlode is measured the way a user runs it, one escript process per call from start to exit, with [himorime](https://github.com/nao1215/himorime). himorime builds the escript (`gleam build` and `gleam run -m gleescript`, as release.yml and the Dockerfile do), runs each command in interleaved rounds, and reports latency, CPU time, peak RSS and, for the large projects, throughput in queries per second.

```console
$ go install github.com/nao1215/himorime@latest
$ just bench            # himorime run bench
$ just bench-compare    # himorime compare --against main bench
```

The escript runs on the Erlang runtime and `generate` runs `gleam format` on what it writes, so `escript` and `gleam` must be on PATH.

## Regression suite: himorime.yaml

`just bench-compare` checks main out into a temporary Git worktree, builds it and your working tree, and measures both in the same rounds, so a background job slows both revisions instead of one. `BASE=v0.32.0 just bench-compare` compares against another revision. `himorime run --filter '^generate 1k$' bench` measures one benchmark, and `himorime run --tag smoke bench` only the small ones.

On a pull request, `.github/workflows/bench.yml` runs `himorime ci bench` the same way, with the base of the pull request as the base, on one runner. The job fails when a command is slower, uses more CPU time or more memory than the base beyond the tolerance in `himorime.yaml` with 95% confidence. A difference too close to call is reported as inconclusive and does not fail the job. The comparison is on the job summary page and the JSON report is kept as an artifact.

The number in a benchmark name is the number of queries in the project. The projects are SQLite projects written by `gen.sh` before measuring, so no fixture is added, and both revisions run the working tree's `gen.sh`. Every ten queries share one pair of tables (`authorsN`, `booksN`), and the queries cycle through `:one`, `:many` with a JOIN, and `:exec`.

| Benchmark | Command | Measures |
|-----------|---------|----------|
| `version` | `sqlode version` | starting the escript on the BEAM |
| `generate 10` | `generate` | parsing, analysing, generating and formatting a small project, where start-up dominates |
| `generate 1k` | `generate` | the same on 1000 queries over 100 pairs of tables |
| `verify 1k` | `verify` | the check a CI job runs before `generate`, on the same 1000 queries; it writes nothing |
| `generate error` | `generate` with a missing config | the failing path, exit 1 |

Not measured:

- `sqlode init`: it writes fixed files and does no work that grows with anything.
- PostgreSQL and MySQL projects, and the generated code against a live database: those need a server, and the suite does not go to the network. They are covered by the integration tests.
- The Docker image: it runs the same escript on the same runtime.

Numbers from different machines are not comparable; compare revisions on one machine, as `just bench-compare` and CI do.
