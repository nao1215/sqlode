# Migrating from sqlc

sqlode follows sqlc conventions, so most SQL files move over unchanged. The differences:

| | sqlc | sqlode |
|---|---|---|
| Install | Standalone binary (`brew install sqlc`) | Escript or `gleam add sqlode` |
| Config | `sqlc.yaml` / `sqlc.json` | `sqlode.yaml` (v2 format only), also accepts `sqlc.yaml` / `sqlc.yml` / `sqlc.json` on autodiscovery |
| Generate | `sqlc generate` | `sqlode generate` |
| Init | `sqlc init` | `sqlode init` |
| Vet/Verify | `sqlc vet`, `sqlc verify` | `sqlode verify` (static analysis + `query_parameter_limit`) |
| Target language | Go, Python, Kotlin, etc. | Gleam |
| Runtime | Generated code is self-contained | Generated code imports `sqlode/runtime` by default; set `vendor_runtime: true` to vendor a copy and drop the runtime dependency (see [Self-contained generation](../README.md#self-contained-generation-vendor_runtime)) |

## Migration steps

1. Install sqlode; see [Install](../README.md#install).
2. Keep your existing `sqlc.yaml` / `sqlc.yml` / `sqlc.json`. `sqlode generate` auto-discovers them in the current directory when no `--config` is passed (search order: `sqlode.yaml`, `sqlode.yml`, `sqlc.yaml`, `sqlc.yml`, `sqlc.json`; pass `--config=<path>` if more than one exists). If you prefer a dedicated file, copy the config to `sqlode.yaml`. Either way, keep `version: "2"` and the `sql` blocks and replace the `gen` section:

   ```yaml
   gen:
     gleam:
       out: "src/db"
       runtime: "raw"   # or "native"
   ```

3. Swap `sqlc.arg` / `sqlc.narg` / `sqlc.slice` / `sqlc.embed` for the `sqlode.*` versions in your `.sql` files. The `@name` shorthand is unchanged.
4. Run `sqlode generate` (or `gleam run -m sqlode -- generate`).

## Unsupported sqlc features

- `sqlc.yaml` v1 format
- `vet` and `verify` commands
- `emit_json_tags` and other sqlc-specific emit options not listed above
