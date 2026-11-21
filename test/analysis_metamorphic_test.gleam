//// Metamorphic tests for the query parser and analyser. The exact
//// parameters and result columns of a query are hard to write down for
//// every input, but some rewrites of a query file must not change them:
////
//// - the amount and kind of whitespace between tokens (spaces, tabs and
////   line breaks),
//// - a `--` comment at the end of a line,
//// - the letter case of SQL keywords,
//// - the order of the queries in the file.
////
//// Each relation is checked on every fixture pair below, on all three
//// engines. String literals and quoted identifiers are never touched, and
//// neither are the `-- name:` annotation lines. The rewrites that take
//// random choices draw them from metamon, so the nightly property job
//// explores more of them.

import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import simplifile
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_parser
import sqlode/internal/schema_parser
import sqlode/runtime

type Case {
  Case(engine: model.Engine, schema: String, queries: String)
}

/// A case read and analysed once. The property tests rewrite `text` many
/// times per run, so the schema, the original file and its analysis are
/// computed up front rather than for every sample.
type Fixture {
  Fixture(
    case_: Case,
    catalog: model.Catalog,
    text: String,
    expected: List(Analysis),
  )
}

const cases = [
  Case(model.PostgreSQL, "schema.sql", "query.sql"),
  Case(model.PostgreSQL, "postgresql_schema.sql", "postgresql_crud_query.sql"),
  Case(model.PostgreSQL, "readme_schema.sql", "readme_query.sql"),
  Case(model.PostgreSQL, "complex_schema.sql", "complex_query.sql"),
  Case(model.PostgreSQL, "all_types_schema.sql", "all_types_query.sql"),
  Case(model.PostgreSQL, "enum_schema.sql", "enum_query.sql"),
  Case(model.PostgreSQL, "array_schema.sql", "array_query.sql"),
  Case(model.PostgreSQL, "typecast_schema.sql", "typecast_query.sql"),
  Case(model.PostgreSQL, "compound_schema.sql", "compound_query.sql"),
  Case(model.PostgreSQL, "multi_table_schema.sql", "multi_table_query.sql"),
  Case(
    model.PostgreSQL,
    "nullable_strong_schema.sql",
    "nullable_strong_query.sql",
  ),
  Case(model.MySQL, "mysql_schema.sql", "mysql_query.sql"),
  Case(model.MySQL, "mysql_real_schema.sql", "mysql_real_query.sql"),
  Case(model.MySQL, "mysql_advanced_schema.sql", "mysql_advanced_query.sql"),
  Case(model.SQLite, "sqlite_schema.sql", "sqlite_crud_query.sql"),
  Case(model.SQLite, "all_commands_schema.sql", "all_commands_query.sql"),
  Case(model.SQLite, "sqlite_advanced_schema.sql", "sqlite_advanced_query.sql"),
]

type Analysis {
  Analysis(
    name: String,
    command: runtime.QueryCommand,
    params: List(model.QueryParam),
    result_columns: List(model.ResultItem),
  )
}

/// What the generated code depends on: per query name, its command,
/// parameters and result columns. The SQL text itself is left out, since
/// the rewrites change it on purpose. A file that no longer parses or
/// analyses is `Error(Nil)`.
fn analysis(
  c: Case,
  catalog: model.Catalog,
  query_text: String,
) -> Result(List(Analysis), Nil) {
  let naming_ctx = naming.new()
  case query_parser.parse_file(c.queries, c.engine, naming_ctx, query_text) {
    Error(_) -> Error(Nil)
    Ok(parsed) ->
      case
        query_analyzer.analyze_queries(c.engine, catalog, naming_ctx, parsed)
      {
        Error(_) -> Error(Nil)
        Ok(analyzed) ->
          analyzed
          |> list.map(fn(query) {
            Analysis(
              name: query.base.name,
              command: query.base.command,
              params: query.params,
              result_columns: query.result_columns,
            )
          })
          |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
          |> Ok
      }
  }
}

fn fixtures() -> List(Fixture) {
  list.map(cases, fn(c) {
    let assert Ok(schema_text) = simplifile.read("test/fixtures/" <> c.schema)
      as "the fixture schema is readable"
    let assert Ok(#(catalog, _)) =
      schema_parser.parse_files_with_engine(
        [#(c.schema, schema_text)],
        c.engine,
      )
      as "the fixture schema parses"
    let assert Ok(text) = simplifile.read("test/fixtures/" <> c.queries)
      as "the fixture queries are readable"
    let assert Ok(expected) = analysis(c, catalog, text)
      as "every fixture pair analyses"
    Fixture(case_: c, catalog:, text:, expected:)
  })
}

fn engine_name(engine: model.Engine) -> String {
  case engine {
    model.PostgreSQL -> "postgresql"
    model.MySQL -> "mysql"
    model.SQLite -> "sqlite"
  }
}

fn assert_same(f: Fixture, rewritten: String, relation: String) -> Bool {
  let c = f.case_
  case analysis(c, f.catalog, rewritten) {
    Ok(got) if got == f.expected -> True
    Ok(_) ->
      panic as {
        relation
        <> " changed the analysis of "
        <> c.queries
        <> " ("
        <> engine_name(c.engine)
        <> "). Rewritten file:\n"
        <> rewritten
      }
    Error(Nil) ->
      panic as {
        relation
        <> " made "
        <> c.queries
        <> " ("
        <> engine_name(c.engine)
        <> ") fail to parse or analyse. Rewritten file:\n"
        <> rewritten
      }
  }
}

// ---------- rewriting outside quotes ----------

/// Apply `rewrite` to each run of characters outside string literals,
/// quoted identifiers and backquoted identifiers, on every line that is not
/// an annotation or a comment line.
fn map_unquoted(text: String, rewrite: fn(String) -> String) -> String {
  text
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.starts_with(string.trim_start(line), "--") {
      True -> line
      False -> map_line(string.to_graphemes(line), "", None, [], rewrite)
    }
  })
  |> string.join("\n")
}

type Quote {
  None
  In(String)
}

fn map_line(
  rest: List(String),
  run: String,
  quote: Quote,
  acc: List(String),
  rewrite: fn(String) -> String,
) -> String {
  case rest, quote {
    [], None -> string.concat(list.reverse([rewrite(run), ..acc]))
    [], In(_) -> string.concat(list.reverse([run, ..acc]))
    // The rest of the line is a comment: keep it as it is.
    ["-", "-", ..], None ->
      string.concat(list.reverse([string.concat(rest), rewrite(run), ..acc]))
    [g, ..tail], None ->
      case g == "'" || g == "\"" || g == "`" {
        True -> map_line(tail, g, In(g), [rewrite(run), ..acc], rewrite)
        False -> map_line(tail, run <> g, None, acc, rewrite)
      }
    [g, ..tail], In(q) ->
      case g == q {
        True -> map_line(tail, "", None, [run <> g, ..acc], rewrite)
        False -> map_line(tail, run <> g, quote, acc, rewrite)
      }
  }
}

// ---------- relations ----------

const keywords = [
  "select", "from", "where", "and", "or", "not", "null", "order", "by", "group",
  "having", "limit", "offset", "insert", "into", "values", "update", "set",
  "delete", "returning", "join", "left", "inner", "on", "as", "in", "is",
  "distinct", "count", "desc", "asc", "exists", "case", "when", "then", "else",
  "end", "union", "all", "with",
]

fn flip_keyword_case(text: String, upper: Bool) -> String {
  let lookup = dict.from_list(list.map(keywords, fn(k) { #(k, Nil) }))
  map_unquoted(text, fn(run) {
    run
    |> split_words
    |> list.map(fn(word) {
      case dict.has_key(lookup, string.lowercase(word)) {
        True ->
          case upper {
            True -> string.uppercase(word)
            False -> string.lowercase(word)
          }
        False -> word
      }
    })
    |> string.concat
  })
}

/// Split into maximal runs of word characters and single other characters,
/// keeping every character.
fn split_words(text: String) -> List(String) {
  text
  |> string.to_graphemes
  |> list.fold([], fn(acc, g) {
    let word = is_word(g)
    case acc {
      [last, ..rest] ->
        case word && is_word_run(last) {
          True -> [last <> g, ..rest]
          False -> [g, ..acc]
        }
      [] -> [g]
    }
  })
  |> list.reverse
}

fn is_word(g: String) -> Bool {
  case g {
    "_" -> True
    _ -> string.lowercase(g) != string.uppercase(g) || is_digit(g)
  }
}

fn is_digit(g: String) -> Bool {
  case int.parse(g) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn is_word_run(s: String) -> Bool {
  case string.last(s) {
    Ok(g) -> is_word(g)
    Error(_) -> False
  }
}

/// Replace every single space outside quotes with one of the whitespace
/// sequences in `choices`, picked in turn.
fn respace(text: String, choices: List(String)) -> String {
  let choices = case choices {
    [] -> [" "]
    _ -> choices
  }
  map_unquoted(text, fn(run) {
    let parts = string.split(run, " ")
    let n = list.length(choices)
    parts
    |> list.index_map(fn(part, i) {
      case i {
        0 -> part
        _ -> {
          let assert Ok(sep) = choices |> list.drop({ i - 1 } % n) |> list.first
            as "the choice list is not empty"
          sep <> part
        }
      }
    })
    |> string.concat
  })
}

/// Split a query file into its `-- name:` blocks.
fn blocks(text: String) -> #(String, List(String)) {
  let assert [head, ..rest] = string.split(text, "-- name:")
    as "split always returns a list"
  #(head, list.map(rest, fn(block) { "-- name:" <> block }))
}

fn ensure_newline(block: String) -> String {
  case string.ends_with(block, "\n") {
    True -> block
    False -> block <> "\n"
  }
}

// ---------- tests ----------

pub fn fixtures_analyse_test() -> Nil {
  assert list.length(fixtures()) == list.length(cases)
}

pub fn keyword_case_does_not_change_analysis_test() -> Nil {
  list.each(fixtures(), fn(f) {
    assert assert_same(
      f,
      flip_keyword_case(f.text, True),
      "upper-casing the keywords",
    )
    assert assert_same(
      f,
      flip_keyword_case(f.text, False),
      "lower-casing the keywords",
    )
  })
}

pub fn whitespace_does_not_change_analysis_test() -> Nil {
  let separator = generator.element_of([" ", "  ", "\t", "\n", " \n  ", "\n\t"])
  let fixtures = fixtures()
  metamon.forall(
    generator.list_of(separator, range.constant(1, 6)),
    fn(choices) {
      list.all(fixtures, fn(f) {
        assert_same(f, respace(f.text, choices), "changing whitespace")
      })
    },
  )
}

pub fn trailing_comment_does_not_change_analysis_test() -> Nil {
  list.each(fixtures(), fn(f) {
    let rewritten =
      f.text
      |> string.split("\n")
      |> list.map(fn(line) {
        let trimmed = string.trim(line)
        case
          trimmed == ""
          || string.starts_with(trimmed, "--")
          || string.contains(line, "'")
          || string.contains(line, "--")
        {
          True -> line
          False -> line <> " -- note: 'quoted' and $9 inside a comment"
        }
      })
      |> string.join("\n")
    assert assert_same(f, rewritten, "adding end-of-line comments")
  })
}

pub fn query_order_does_not_change_analysis_test() -> Nil {
  let fixtures = fixtures()
  metamon.forall(generator.int(range.constant(0, 1000)), fn(seed) {
    list.all(fixtures, fn(f) {
      let #(head, queries) = blocks(f.text)
      let shuffled =
        queries
        |> list.map(ensure_newline)
        |> list.index_map(fn(block, i) { #({ i * 7919 + seed } % 1009, block) })
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
        |> list.map(fn(pair) { pair.1 })
      assert_same(f, head <> string.concat(shuffled), "reordering the queries")
    })
  })
}
