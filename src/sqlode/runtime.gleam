import gleam/int
import gleam/list
import gleam/option
import gleam/string

pub type QueryCommand {
  One
  Many
  Exec
  ExecResult
  ExecRows
  ExecLastId
  BatchOne
  BatchMany
  BatchExec
  CopyFrom
}

pub type Value {
  Null
  String(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  Bytes(BitArray)
  Array(List(Value))
}

/// Lightweight metadata for a query, used by the generated `all()` function
/// to list every query in a module without carrying encoder closures.
pub type QueryInfo {
  QueryInfo(name: String, sql: String, command: QueryCommand, param_count: Int)
}

/// Placeholder style used by the target database driver.
///
/// SQLite accepts both `?1`-style and bare-`?`-style placeholders, so
/// the engine column below marks both rows ✓ for sqlite. Pick the
/// variant whose syntax matches the query strings your codegen — or
/// hand-rolled SQL — actually emits.
///
/// | Variant              | Syntax        | PostgreSQL | MySQL | SQLite |
/// | -------------------- | ------------- | ---------- | ----- | ------ |
/// | `DollarNumbered`     | `$1`, `$2`, … | ✓          | —     | —      |
/// | `QuestionNumbered`   | `?1`, `?2`, … | —          | —     | ✓      |
/// | `QuestionPositional` | bare `?`      | —          | ✓     | ✓      |
pub type PlaceholderStyle {
  /// PostgreSQL: `$1`, `$2`, … Indices are 1-based and explicit.
  DollarNumbered
  /// SQLite numbered form: `?1`, `?2`, … Indices are 1-based and
  /// explicit. PostgreSQL and MySQL do not accept this syntax.
  QuestionNumbered
  /// Bare `?` matched by position. Used by both MySQL and SQLite.
  /// PostgreSQL does not accept this syntax.
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

/// Construct a `RawQuery` directly. Behaviour is identical to
/// invoking the `RawQuery(...)` constructor; the named helper exists
/// so the intent ("this is a hand-rolled `RawQuery`, not codegen
/// output") is obvious at the call site and discoverable via the
/// docs.
///
/// Use this helper when:
///
/// - using `sqlode/runtime` as a library, bypassing `sqlode generate`
///   codegen for hand-rolled queries that live next to your handler
///   code;
/// - writing a custom adapter (in-memory test database, SQLite WASM
///   shim, query-log middleware, ...) that needs to exercise
///   `prepare(query, params)` against a hand-rolled `RawQuery`
///   without running the codegen pipeline; or
/// - writing property / regression tests for the runtime surface
///   (`prepare`, `expand_slice_placeholders`) without regenerating
///   fixtures every time.
///
/// Production callers who run codegen should keep using the
/// `RawQuery` values `sqlode generate` produces from declarative SQL
/// fixtures — they pin the SQL string and parameter shape next to the
/// schema, which this helper does not.
pub fn raw_query(
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

/// Thin wrapper around `raw_query/7` for hand-rolled queries that do
/// not use slice-expanded `IN ($1)` placeholders. Forwards every
/// labelled argument to `raw_query` and supplies
/// `slice_info: fn(_) { [] }` so ad-hoc callers do not have to repeat
/// the always-empty lambda at every call site.
///
/// Reach for `raw_query_simple` when:
///
/// - writing a hand-rolled `INSERT` / `UPDATE` / `DELETE` or a fixed-
///   shape `SELECT` whose SQL has zero slice markers; or
/// - prototyping a query against `sqlode/runtime` as a library, before
///   moving the SQL into a declarative fixture and regenerating
///   through `sqlode generate`.
///
/// Keep using `raw_query/7` when the SQL contains slice-expanded
/// `IN ($N)` placeholders — those queries need the real `slice_info`
/// callback to expand at `prepare/2` time. `sqlode generate` codegen
/// continues to emit `raw_query/7` (or the bare `RawQuery(...)`
/// constructor) so this wrapper only affects ad-hoc callers.
pub fn raw_query_simple(
  name name: String,
  sql sql: String,
  command command: QueryCommand,
  param_count param_count: Int,
  placeholder_style placeholder_style: PlaceholderStyle,
  encode encode: fn(p) -> List(Value),
) -> RawQuery(p) {
  raw_query(
    name: name,
    sql: sql,
    command: command,
    param_count: param_count,
    placeholder_style: placeholder_style,
    encode: encode,
    slice_info: fn(_) { [] },
  )
}

/// Deprecated alias for `raw_query/7`. The `_for_test` suffix
/// discouraged library-mode callers from using the only sanctioned
/// non-constructor path even though library use is exactly what the
/// helper was built for. `raw_query/7` carries the same behaviour
/// without the suffix.
@deprecated("Use `runtime.raw_query` instead. The `_for_test` suffix discouraged library-mode callers even though library use is exactly what the helper was built for.")
pub fn raw_query_for_test(
  name name: String,
  sql sql: String,
  command command: QueryCommand,
  param_count param_count: Int,
  placeholder_style placeholder_style: PlaceholderStyle,
  encode encode: fn(p) -> List(Value),
  slice_info slice_info: fn(p) -> List(#(Int, Int)),
) -> RawQuery(p) {
  raw_query(
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
  Null
}

pub fn string(value: String) -> Value {
  String(value)
}

pub fn int(value: Int) -> Value {
  Int(value)
}

pub fn float(value: Float) -> Value {
  Float(value)
}

pub fn bool(value: Bool) -> Value {
  Bool(value)
}

pub fn bytes(value: BitArray) -> Value {
  Bytes(value)
}

pub fn array(values: List(Value)) -> Value {
  Array(values)
}

pub fn nullable(value: option.Option(a), encode: fn(a) -> Value) -> Value {
  case value {
    option.Some(v) -> encode(v)
    option.None -> Null
  }
}

/// Marker prefix emitted by the generator for a regular `sqlode.arg` /
/// `sqlode.narg` / `@name` parameter at the given **1-based** index.
/// Rendered into the final placeholder at runtime by
/// `expand_slice_placeholders`.
///
/// Panics with
/// `"sqlode.runtime.param_marker: index must be >= 1 (1-based) (got <n>)"`
/// when `index < 1`. The runtime expand step is keyed by 1-based positions,
/// so a `0` or negative index would either round-trip to a syntactically
/// broken SQL string or silently match an unrelated marker — both
/// constitute SQL-shape bugs. Use `param_marker_checked/1` instead when
/// the caller wants to surface the precondition as a `Result` (for
/// example, in a custom adapter that accepts user-supplied indices).
pub fn param_marker(index: Int) -> String {
  case index < 1 {
    True ->
      panic as {
        "sqlode.runtime.param_marker: index must be >= 1 (1-based) (got "
        <> int.to_string(index)
        <> ")"
      }
    False -> "__sqlode_param_" <> int.to_string(index) <> "__"
  }
}

/// Marker prefix emitted by the generator for a `sqlode.slice` parameter at
/// the given **1-based** index. Rendered into the expanded placeholder list
/// at runtime by `expand_slice_placeholders`.
///
/// Panics with
/// `"sqlode.runtime.slice_marker: index must be >= 1 (1-based) (got <n>)"`
/// when `index < 1`. Same reasoning as `param_marker/1`. Use
/// `slice_marker_checked/1` instead when the caller wants to surface the
/// precondition as a `Result`.
pub fn slice_marker(index: Int) -> String {
  case index < 1 {
    True ->
      panic as {
        "sqlode.runtime.slice_marker: index must be >= 1 (1-based) (got "
        <> int.to_string(index)
        <> ")"
      }
    False -> "__sqlode_slice_" <> int.to_string(index) <> "__"
  }
}

/// Why `param_marker_checked` / `slice_marker_checked` rejected its input.
///
/// - `MarkerIndexNonPositive` — the supplied `index` is `<= 0`. Marker
///   indices are 1-based; values below `1` would either fail to round-trip
///   through `expand_slice_placeholders` (leaving the literal marker in
///   the SQL → runtime SQL syntax error) or silently match an unrelated
///   marker (silent SQL-shape bug). Same precondition as the panicking
///   `param_marker/1` / `slice_marker/1` constructors.
pub type MarkerError {
  MarkerIndexNonPositive(index: Int)
}

/// Like `param_marker/1`, but returns the precondition failure as a
/// `Result` instead of panicking. Use this when `index` comes from a
/// custom adapter or hand-rolled `RawQuery` and the caller wants to
/// surface bookkeeping mistakes without crashing the process. Same
/// reasoning as `expand_slice_placeholders_checked` (#546).
///
/// On success the returned string is identical to `param_marker(index)`.
pub fn param_marker_checked(index: Int) -> Result(String, MarkerError) {
  case index < 1 {
    True -> Error(MarkerIndexNonPositive(index: index))
    False -> Ok("__sqlode_param_" <> int.to_string(index) <> "__")
  }
}

/// Like `slice_marker/1`, but returns the precondition failure as a
/// `Result` instead of panicking. Same shape and reasoning as
/// `param_marker_checked/1`.
pub fn slice_marker_checked(index: Int) -> Result(String, MarkerError) {
  case index < 1 {
    True -> Error(MarkerIndexNonPositive(index: index))
    False -> Ok("__sqlode_slice_" <> int.to_string(index) <> "__")
  }
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
    Error(TotalParamsNegative(total)) ->
      panic as {
        "sqlode.expand_slice_placeholders: total_params must be >= 0 (got "
        <> int.to_string(total)
        <> "). Use expand_slice_placeholders_checked for a Result-returning variant. (#565)"
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
/// - `TotalParamsNegative` covers a `total_params` that is below 0.
///   Parameter counts cannot be negative; without this check the
///   `int.range` loop in `expand_slice_placeholders` would call
///   `param_marker(0)`, which panics post-#551. (#565)
pub type ExpandError {
  SliceLengthNegative(index: Int, length: Int)
  SliceIndexOutOfRange(index: Int, total_params: Int)
  TotalParamsNegative(total_params: Int)
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
  case total_params < 0 {
    True -> Error(TotalParamsNegative(total_params: total_params))
    False ->
      case validate_slices(slices, total_params) {
        Error(e) -> Error(e)
        Ok(_) -> Ok(expand_slice_placeholders(sql, slices, total_params, style))
      }
  }
}

fn validate_slices(
  slices: List(#(Int, Int)),
  total_params: Int,
) -> Result(Nil, ExpandError) {
  case total_params < 0 {
    True -> Error(TotalParamsNegative(total_params: total_params))
    False -> validate_slice_entries(slices, total_params)
  }
}

fn validate_slice_entries(
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
            False -> validate_slice_entries(rest, total_params)
          }
      }
  }
}
