import gleam/int
import gleam/list
import gleam/option
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
  SqlArray(List(Value))
}

/// Lightweight metadata for a query, used by the generated `all()` function
/// to list every query in a module without carrying encoder closures.
pub type QueryInfo {
  QueryInfo(name: String, sql: String, command: QueryCommand, param_count: Int)
}

/// Placeholder style used by the target database driver.
///
/// - `DollarNumbered` — PostgreSQL style: `$1`, `$2`, ...
/// - `QuestionNumbered` — SQLite style: `?1`, `?2`, ...
/// - `QuestionPositional` — MySQL style: bare `?` (matched by position)
pub type PlaceholderStyle {
  DollarNumbered
  QuestionNumbered
  QuestionPositional
}

/// A typed raw query descriptor that bundles SQL metadata with its parameter
/// encoder.  The type parameter `p` represents the parameter type for this
/// query, which ties the query to its expected parameters at the type level.
///
/// `placeholder_style` records the dialect the generator emitted the SQL
/// for, so callers of `prepare` do not need to know or repeat the engine
/// choice: they pass the query and parameters and get back a final SQL
/// string already rendered for the target driver.
pub type RawQuery(p) {
  RawQuery(
    name: String,
    sql: String,
    command: QueryCommand,
    param_count: Int,
    placeholder_style: PlaceholderStyle,
    encode: fn(p) -> List(Value),
    slice_info: fn(p) -> List(#(Int, Int)),
  )
}

/// Construct a `RawQuery` directly. **Test-only**: production callers
/// should always go through codegen-emitted `RawQuery` values, which
/// `sqlode generate` produces from declarative SQL fixtures.
///
/// Use this helper when:
///
/// - writing a custom adapter (in-memory test database, SQLite WASM
///   shim, query-log middleware, ...) that needs to exercise
///   `prepare(query, params)` against a hand-rolled `RawQuery`
///   without running the codegen pipeline; or
/// - writing property / regression tests for the runtime surface
///   (`prepare`, `expand_slice_placeholders`) without regenerating
///   fixtures every time.
///
/// Behaviour is identical to invoking the `RawQuery(...)` constructor
/// directly; the named helper exists so the intent (\"this is a
/// hand-rolled RawQuery, not codegen output\") is obvious at the call
/// site and discoverable via the docs.
pub fn raw_query_for_test(
  name name: String,
  sql sql: String,
  command command: QueryCommand,
  param_count param_count: Int,
  placeholder_style placeholder_style: PlaceholderStyle,
  encode encode: fn(p) -> List(Value),
  slice_info slice_info: fn(p) -> List(#(Int, Int)),
) -> RawQuery(p) {
  RawQuery(
    name: name,
    sql: sql,
    command: command,
    param_count: param_count,
    placeholder_style: placeholder_style,
    encode: encode,
    slice_info: slice_info,
  )
}

/// Prepare a raw query for execution by encoding parameters and expanding
/// the engine-agnostic placeholder markers that the generator emits. The
/// target placeholder dialect is read from `query.placeholder_style`, so
/// callers no longer need to pass a separate style argument.
/// Returns the final SQL string and the flattened parameter values, ready
/// to be passed to a database driver.
pub fn prepare(query: RawQuery(p), params: p) -> #(String, List(Value)) {
  let values = query.encode(params)
  let slices = query.slice_info(params)
  let sql =
    expand_slice_placeholders(
      query.sql,
      slices,
      query.param_count,
      query.placeholder_style,
    )
  #(sql, values)
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

pub fn array(values: List(Value)) -> Value {
  SqlArray(values)
}

pub fn nullable(value: option.Option(a), encode: fn(a) -> Value) -> Value {
  case value {
    option.Some(v) -> encode(v)
    option.None -> SqlNull
  }
}

/// Marker prefix emitted by the generator for a regular `sqlode.arg` /
/// `sqlode.narg` / `@name` parameter at the given 1-based index.
/// Rendered into the final placeholder at runtime by `expand_slice_placeholders`.
pub fn param_marker(index: Int) -> String {
  "__sqlode_param_" <> int.to_string(index) <> "__"
}

/// Marker prefix emitted by the generator for a `sqlode.slice` parameter at
/// the given 1-based index. Rendered into the expanded placeholder list at
/// runtime by `expand_slice_placeholders`.
pub fn slice_marker(index: Int) -> String {
  "__sqlode_slice_" <> int.to_string(index) <> "__"
}

/// Render a parameter marker into the final engine-specific placeholder.
///
/// The generator emits `__sqlode_param_N__` / `__sqlode_slice_N__` in the SQL
/// template regardless of the target engine. At runtime this function
/// replaces each marker with the correct placeholder string (for example
/// `$3` for PostgreSQL, `?3` for SQLite, `?` for MySQL) and expands slice
/// markers to a comma-separated list sized by the caller-provided
/// `slices`. Non-slice markers are renumbered sequentially across the
/// whole SQL text so that slices that precede them shift their index.
///
/// Using markers instead of rewriting `prefix<>index` directly means
/// placeholder-like text inside string literals or comments is never
/// touched, and MySQL (which uses bare `?` rather than `?N`) works
/// without special-casing the placeholder format.
pub fn expand_slice_placeholders(
  sql: String,
  slices: List(#(Int, Int)),
  total_params: Int,
  style: PlaceholderStyle,
) -> String {
  case validate_slices(slices, total_params) {
    Ok(_) -> Nil
    Error(SliceLengthNegative(index, length)) ->
      panic as {
        "sqlode.expand_slice_placeholders: slice length must be >= 0 (got index="
        <> int.to_string(index)
        <> ", length="
        <> int.to_string(length)
        <> ")"
      }
    Error(SliceIndexOutOfRange(index, total)) ->
      panic as {
        "sqlode.expand_slice_placeholders: slice index must be in 1.."
        <> int.to_string(total)
        <> " (got index="
        <> int.to_string(index)
        <> ", total_params="
        <> int.to_string(total)
        <> ")"
      }
  }
  let #(_, mapping) =
    int.range(
      from: 1,
      to: total_params + 1,
      with: #(1, []),
      run: fn(acc, orig_idx) {
        let #(next_new_idx, map) = acc
        case list.find(slices, fn(s) { s.0 == orig_idx }) {
          Ok(#(_, len)) -> {
            let marker = slice_marker(orig_idx)
            case len {
              0 -> #(next_new_idx, [#(marker, "NULL"), ..map])
              _ -> {
                let expanded =
                  int.range(
                    from: next_new_idx,
                    to: next_new_idx + len,
                    with: [],
                    run: fn(items, i) {
                      [render_placeholder(style, i), ..items]
                    },
                  )
                  |> list.reverse
                  |> string.join(", ")
                #(next_new_idx + len, [#(marker, expanded), ..map])
              }
            }
          }
          Error(_) -> {
            let marker = param_marker(orig_idx)
            #(next_new_idx + 1, [
              #(marker, render_placeholder(style, next_new_idx)),
              ..map
            ])
          }
        }
      },
    )

  mapping
  |> list.reverse
  |> list.fold(sql, fn(s, entry) {
    let #(marker, replacement) = entry
    string.replace(s, marker, replacement)
  })
}

fn render_placeholder(style: PlaceholderStyle, index: Int) -> String {
  case style {
    DollarNumbered -> "$" <> int.to_string(index)
    QuestionNumbered -> "?" <> int.to_string(index)
    QuestionPositional -> "?"
  }
}

/// Why `expand_slice_placeholders_checked` rejected its input.
///
/// - `SliceLengthNegative` covers a `slices` entry whose length is
///   negative. Lengths must be `>= 0` (zero is permitted; the
///   placeholder list collapses to `NULL` per the SQL `IN ()` rewrite
///   convention).
/// - `SliceIndexOutOfRange` covers a `slices` entry whose 1-based
///   index falls outside `[1, total_params]`. Indices outside that
///   window can never match the loop's `orig_idx` and are silently
///   ignored otherwise.
pub type ExpandError {
  SliceLengthNegative(index: Int, length: Int)
  SliceIndexOutOfRange(index: Int, total_params: Int)
}

/// Like `expand_slice_placeholders`, but returns the validation
/// failure as a `Result` instead of panicking. Use this when `slices`
/// or `total_params` come from a custom adapter / hand-rolled
/// `RawQuery` and the caller wants to surface bookkeeping mistakes
/// without crashing the process.
///
/// On success the returned string is identical to
/// `expand_slice_placeholders(sql, slices, total_params, style)`.
pub fn expand_slice_placeholders_checked(
  sql: String,
  slices: List(#(Int, Int)),
  total_params: Int,
  style: PlaceholderStyle,
) -> Result(String, ExpandError) {
  case validate_slices(slices, total_params) {
    Error(e) -> Error(e)
    Ok(_) -> Ok(expand_slice_placeholders(sql, slices, total_params, style))
  }
}

fn validate_slices(
  slices: List(#(Int, Int)),
  total_params: Int,
) -> Result(Nil, ExpandError) {
  case slices {
    [] -> Ok(Nil)
    [#(idx, len), ..rest] ->
      case len < 0 {
        True -> Error(SliceLengthNegative(index: idx, length: len))
        False ->
          case idx < 1 || idx > total_params {
            True ->
              Error(SliceIndexOutOfRange(index: idx, total_params: total_params))
            False -> validate_slices(rest, total_params)
          }
      }
  }
}
