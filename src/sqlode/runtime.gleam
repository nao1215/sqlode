import gleam/int
import gleam/list
import gleam/string

pub type QueryCommand {
  QueryOne
  QueryMany
  QueryExec
  QueryExecResult
  QueryExecRows
  QueryExecLastId
  QueryBatchOne
  QueryBatchMany
  QueryBatchExec
  QueryCopyFrom
}

pub type Value {
  SqlNull
  SqlString(String)
  SqlInt(Int)
  SqlFloat(Float)
  SqlBool(Bool)
  SqlBytes(BitArray)
}

/// A typed raw query descriptor that bundles SQL metadata with its parameter
/// encoder.  The type parameter `p` represents the parameter type for this
/// query, which ties the query to its expected parameters at the type level.
pub type RawQuery(p) {
  RawQuery(
    name: String,
    sql: String,
    command: QueryCommand,
    param_count: Int,
    encode: fn(p) -> List(Value),
    slice_info: fn(p) -> List(#(Int, Int)),
  )
}

/// Prepare a raw query for execution by encoding parameters and expanding
/// slice placeholders.  Returns the final SQL string and the flattened
/// parameter values, ready to be passed to a database driver.
///
/// For queries without slices the SQL is returned unchanged.
///
/// - `prefix` – placeholder prefix: `"$"` for PostgreSQL, `"?"` for SQLite
pub fn prepare(
  query: RawQuery(p),
  params: p,
  prefix: String,
) -> #(String, List(Value)) {
  let values = query.encode(params)
  let slices = query.slice_info(params)
  case slices {
    [] -> #(query.sql, values)
    _ -> {
      let sql =
        expand_slice_placeholders(query.sql, slices, query.param_count, prefix)
      #(sql, values)
    }
  }
}

pub fn null() -> Value {
  SqlNull
}

pub fn string(value: String) -> Value {
  SqlString(value)
}

pub fn int(value: Int) -> Value {
  SqlInt(value)
}

pub fn float(value: Float) -> Value {
  SqlFloat(value)
}

pub fn bool(value: Bool) -> Value {
  SqlBool(value)
}

pub fn bytes(value: BitArray) -> Value {
  SqlBytes(value)
}

/// Expand slice placeholders in a SQL string.
///
/// When a query uses `sqlc.slice(ids)`, the parser emits a single placeholder
/// (e.g. `$1` or `?1`).  At runtime the placeholder must be expanded to match
/// the actual list length, and every subsequent placeholder must be renumbered.
///
/// Arguments:
/// - `sql`          – the SQL template with original placeholders
/// - `slices`       – list of `#(original_index, slice_length)` for each slice param
/// - `total_params` – total number of original parameter slots
/// - `prefix`       – placeholder prefix: `"$"` for PostgreSQL, `"?"` for SQLite
///
/// Returns the expanded SQL string.
pub fn expand_slice_placeholders(
  sql: String,
  slices: List(#(Int, Int)),
  total_params: Int,
  prefix: String,
) -> String {
  // Phase 1: Replace all original placeholders with unique markers
  //          (from highest index to lowest to avoid partial matches)
  // Note: int.range excludes the stop value, so use 0 to include 1
  let marked =
    int.range(from: total_params, to: 0, with: sql, run: fn(s, i) {
      string.replace(
        s,
        prefix <> int.to_string(i),
        "{{P" <> int.to_string(i) <> "}}",
      )
    })

  // Phase 2: Compute a mapping from each original index to the new placeholder(s)
  // Note: int.range excludes stop, so use total_params + 1 to include total_params
  let #(_, mapping) =
    int.range(
      from: 1,
      to: total_params + 1,
      with: #(1, []),
      run: fn(acc, orig_idx) {
        let #(next_new_idx, map) = acc
        let is_slice = list.find(slices, fn(s) { s.0 == orig_idx })
        case is_slice {
          Ok(#(_, len)) -> {
            let expanded =
              int.range(
                from: next_new_idx,
                to: next_new_idx + len,
                with: [],
                run: fn(items, i) { [prefix <> int.to_string(i), ..items] },
              )
              |> list.reverse
              |> string.join(", ")
            #(next_new_idx + len, [#(orig_idx, expanded), ..map])
          }
          Error(_) -> {
            #(next_new_idx + 1, [
              #(orig_idx, prefix <> int.to_string(next_new_idx)),
              ..map
            ])
          }
        }
      },
    )

  // Phase 3: Replace markers with final placeholders
  mapping
  |> list.fold(marked, fn(s, entry) {
    let #(orig_idx, replacement) = entry
    string.replace(s, "{{P" <> int.to_string(orig_idx) <> "}}", replacement)
  })
}
