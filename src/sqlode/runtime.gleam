//// Values and query descriptors used by code that `sqlode generate` writes.
////
//// Generated modules import this module. Each query becomes a `RawQuery`
//// whose SQL holds sqlode's own parameter markers. `prepare` turns a query
//// and its parameters into SQL for the target database and the list of
//// values to bind, so a custom adapter only has to hand both to its driver.
////
//// ```gleam
//// let #(sql, values) = runtime.prepare(queries.get_author(), params)
//// // sql: "SELECT id, name FROM authors WHERE id = $1"
//// // values: [runtime.Int(1)]
//// ```
////

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The `-- name: X :command` annotation of a query, which decides what the
/// generated function returns.
///
pub type QueryCommand {
  /// `:one`: at most one row.
  One
  /// `:many`: a list of rows.
  Many
  /// `:exec`: no rows.
  Exec
  /// `:execresult`: the driver's result value.
  ExecResult
  /// `:execrows`: the number of affected rows.
  ExecRows
  /// `:execlastid`: the id of the last inserted row.
  ExecLastId
}

/// A parameter value handed to the database driver.
///
/// Each variant is also a function, so an encoder can be passed where a
/// `fn(a) -> Value` is expected, as in `list.map(ids, runtime.Int)`.
///
pub type Value {
  /// SQL `NULL`.
  Null
  /// A text value.
  String(String)
  /// An integer.
  Int(Int)
  /// A floating point number.
  Float(Float)
  /// A boolean.
  Bool(Bool)
  /// Binary data, such as a `BYTEA` or `BLOB` value.
  Bytes(BitArray)
  /// A PostgreSQL array.
  Array(List(Value))
}

/// The name, SQL and shape of a query, without its parameter encoder.
/// Generated modules list every query as a `QueryInfo` in `all()`.
///
pub type QueryInfo {
  QueryInfo(
    /// The name from `-- name:`.
    name: String,
    /// The SQL with placeholders rendered for the target database.
    sql: String,
    /// The query's annotation.
    command: QueryCommand,
    /// The number of parameters before any slice is expanded.
    param_count: Int,
  )
}

/// The placeholder syntax of the target database driver.
///
/// | Variant              | Syntax        | PostgreSQL | MySQL | SQLite |
/// | -------------------- | ------------- | ---------- | ----- | ------ |
/// | `DollarNumbered`     | `$1`, `$2`, … | ✓          | —     | —      |
/// | `QuestionNumbered`   | `?1`, `?2`, … | —          | —     | ✓      |
/// | `QuestionPositional` | bare `?`      | —          | ✓     | ✓      |
///
pub type PlaceholderStyle {
  /// `$1`, `$2`, …, used by PostgreSQL.
  DollarNumbered
  /// `?1`, `?2`, …, used by SQLite.
  QuestionNumbered
  /// A bare `?` per value, matched by position. Used by MySQL and SQLite.
  QuestionPositional
}

/// A query as `sqlode generate` emits it. The type parameter `p` is the
/// parameter type the query takes.
///
pub type RawQuery(p) {
  RawQuery(
    /// The name from `-- name:`.
    name: String,
    /// The SQL with sqlode's parameter markers in place of placeholders.
    sql: String,
    /// The query's annotation.
    command: QueryCommand,
    /// The number of parameter markers in `sql`.
    param_count: Int,
    /// The placeholder syntax `prepare` renders the markers in.
    placeholder_style: PlaceholderStyle,
    /// Turns the parameters into the values to bind, in placeholder order.
    encode: fn(p) -> List(Value),
    /// Returns `#(index, length)` for each `sqlode.slice` parameter: its
    /// 1-based parameter index and how many values the list holds.
    slice_info: fn(p) -> List(#(Int, Int)),
  )
}

/// Encodes the parameters and renders the SQL in the query's placeholder
/// style. Pass the returned SQL and values to the database driver.
///
/// A `sqlode.slice` parameter becomes one placeholder per list element,
/// and an empty list becomes `NULL`, so `IN (...)` matches no rows.
///
/// ## Examples
///
/// ```gleam
/// let query =
///   runtime.RawQuery(
///     name: "ListBooks",
///     sql: "SELECT id FROM books WHERE author_id = __sqlode_param_1__"
///       <> " AND id IN (__sqlode_slice_2__)",
///     command: runtime.Many,
///     param_count: 2,
///     placeholder_style: runtime.DollarNumbered,
///     encode: fn(p: #(Int, List(Int))) {
///       [runtime.Int(p.0), ..list.map(p.1, runtime.Int)]
///     },
///     slice_info: fn(p: #(Int, List(Int))) { [#(2, list.length(p.1))] },
///   )
///
/// assert runtime.prepare(query, #(7, [1, 2]))
///   == #(
///     "SELECT id FROM books WHERE author_id = $1 AND id IN ($2, $3)",
///     [runtime.Int(7), runtime.Int(1), runtime.Int(2)],
///   )
/// ```
///
/// ## Panics
///
/// Panics when `slice_info` returns an index outside `1..param_count` or a
/// negative length. Generated code never does.
///
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

/// Encodes `Some(x)` with `encode` and `None` as `Null`.
///
/// ## Examples
///
/// ```gleam
/// assert runtime.nullable(Some("Ann"), runtime.String) == runtime.String("Ann")
/// ```
///
/// ```gleam
/// assert runtime.nullable(None, runtime.String) == runtime.Null
/// ```
///
pub fn nullable(value: Option(a), encode: fn(a) -> Value) -> Value {
  case value {
    Some(v) -> encode(v)
    None -> Null
  }
}

/// The marker the generator writes for parameter `index`, which starts at 1.
@internal
pub fn param_marker(index: Int) -> String {
  marker_prefix <> "param_" <> int.to_string(index) <> "__"
}

/// The marker the generator writes for slice parameter `index`, which
/// starts at 1.
@internal
pub fn slice_marker(index: Int) -> String {
  marker_prefix <> "slice_" <> int.to_string(index) <> "__"
}

// Replaces each marker with its placeholder. A slice marker becomes one
// placeholder per element (or `NULL` for an empty list), and the plain
// markers after it are renumbered to follow.
fn expand_slice_placeholders(
  sql: String,
  slices: List(#(Int, Int)),
  total_params: Int,
  style: PlaceholderStyle,
) -> String {
  check_slices(slices, total_params)
  // The first entry for an index wins.
  let slice_lengths =
    list.fold(slices, dict.new(), fn(lengths, slice) {
      case dict.has_key(lengths, slice.0) {
        True -> lengths
        False -> dict.insert(lengths, slice.0, slice.1)
      }
    })
  let replacements = case total_params < 1 {
    True -> dict.new()
    False -> {
      let #(_, replacements) =
        int.range(
          from: 1,
          to: total_params + 1,
          with: #(1, dict.new()),
          run: fn(acc, orig_idx) {
            let #(next_new_idx, replacements) = acc
            case dict.get(slice_lengths, orig_idx) {
              Ok(0) -> #(
                next_new_idx,
                dict.insert(replacements, slice_marker(orig_idx), "NULL"),
              )
              Ok(len) -> {
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
                #(
                  next_new_idx + len,
                  dict.insert(replacements, slice_marker(orig_idx), expanded),
                )
              }
              Error(Nil) -> #(
                next_new_idx + 1,
                dict.insert(
                  replacements,
                  param_marker(orig_idx),
                  render_placeholder(style, next_new_idx),
                ),
              )
            }
          },
        )
      replacements
    }
  }

  replace_markers(sql, replacements)
}

// A wrong slice would leave a marker in the SQL or drop a placeholder, and
// the database would then report a syntax error far from the cause.
fn check_slices(slices: List(#(Int, Int)), total_params: Int) -> Nil {
  list.each(slices, fn(slice) {
    let #(index, length) = slice
    case length < 0, index < 1 || index > total_params {
      True, _ ->
        panic as {
          "sqlode/runtime.prepare: slice length must be >= 0 (got index="
          <> int.to_string(index)
          <> ", length="
          <> int.to_string(length)
          <> ")"
        }
      False, True ->
        panic as {
          "sqlode/runtime.prepare: slice index must be in 1.."
          <> int.to_string(total_params)
          <> " (got index="
          <> int.to_string(index)
          <> ")"
        }
      False, False -> Nil
    }
  })
}

// Replace every marker in `sql` that has an entry in `replacements`,
// in one pass over the string. A marker without an entry, or text
// that only starts like one, is left as it is.
fn replace_markers(sql: String, replacements: Dict(String, String)) -> String {
  case string.split(sql, marker_prefix) {
    [] -> sql
    [first, ..rest] ->
      list.fold(rest, [first], fn(out, part) {
        case split_marker(part) {
          Ok(#(marker, after)) ->
            case dict.get(replacements, marker) {
              Ok(replacement) -> [after, replacement, ..out]
              Error(Nil) -> [part, marker_prefix, ..out]
            }
          Error(Nil) -> [part, marker_prefix, ..out]
        }
      })
      |> list.reverse
      |> string.concat
  }
}

const marker_prefix = "__sqlode_"

// Reads `param_N__` or `slice_N__` at the start of `part`, the text
// after a `__sqlode_` prefix, and returns the whole marker and the
// text after it.
fn split_marker(part: String) -> Result(#(String, String), Nil) {
  let kind_and_rest = case part {
    "param_" <> rest -> Ok(#("param_", rest))
    "slice_" <> rest -> Ok(#("slice_", rest))
    _ -> Error(Nil)
  }
  use #(kind, rest) <- result.try(kind_and_rest)
  use #(digits, after) <- result.try(string.split_once(rest, "__"))
  use index <- result.try(int.parse(digits))
  case int.to_string(index) == digits {
    True -> Ok(#(marker_prefix <> kind <> digits <> "__", after))
    False -> Error(Nil)
  }
}

/// The placeholder for parameter `index` in `style`. The generator uses it
/// so the SQL in `QueryInfo` matches what `prepare` sends.
@internal
pub fn render_placeholder(style: PlaceholderStyle, index: Int) -> String {
  case style {
    DollarNumbered -> "$" <> int.to_string(index)
    QuestionNumbered -> "?" <> int.to_string(index)
    QuestionPositional -> "?"
  }
}
