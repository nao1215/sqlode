# Writing custom adapters

`sqlode generate` writes native adapters for PostgreSQL (`pog`), SQLite (`sqlight`) and MySQL (`shork`). For another backend, such as an in-memory test database, a SQLite-WASM build or a query-log middleware, wire the runtime to your own driver:

1. Build a `runtime.RawQuery(p)` with the SQL string the engine expects,
   the parameter encoder, and the slice metadata function.
2. Call `runtime.prepare(query, params)` to get back the final SQL and
   the flattened `List(Value)`.
3. Hand `(sql, values)` to your driver.

For tests and adapter wiring, build the query with `runtime.raw_query_for_test/7` (documented as test-only) instead of the `RawQuery(...)` constructor:

```gleam
import sqlode/runtime

let query =
  runtime.raw_query_for_test(
    name: "GetUser",
    sql: "SELECT * FROM users WHERE id = " <> runtime.param_marker(1),
    command: runtime.QueryOne,
    param_count: 1,
    placeholder_style: runtime.DollarNumbered,
    encode: fn(id) { [runtime.int(id)] },
    slice_info: fn(_) { [] },
  )
let #(sql, values) = runtime.prepare(query, 42)
// sql    == "SELECT * FROM users WHERE id = $1"
// values == [SqlInt(42)]
```

`test/runtime_property_test.gleam` has longer examples, including slice expansion for all three placeholder styles and the `IN (NULL)` rewrite for empty slices.

`expand_slice_placeholders` panics on malformed `slices` metadata (negative length, out-of-range index), which is fine for generated code. When the metadata comes from elsewhere, use `runtime.expand_slice_placeholders_checked`.
