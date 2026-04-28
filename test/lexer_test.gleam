import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import sqlode/internal/lexer.{
  Comma, Dot, Ident, Keyword, LParen, NumberLit, Operator, Placeholder,
  QuotedIdent, RParen, Semicolon, Star, StringLit,
}
import sqlode/internal/model

pub fn main() {
  gleeunit.main()
}

// --- Basic token tests ---

pub fn simple_select_test() {
  lexer.tokenize("SELECT id, name FROM authors;", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Ident("id"),
    Comma,
    Ident("name"),
    Keyword("from"),
    Ident("authors"),
    Semicolon,
  ])
}

pub fn select_star_test() {
  lexer.tokenize("SELECT * FROM users", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Star,
    Keyword("from"),
    Ident("users"),
  ])
}

pub fn create_table_test() {
  lexer.tokenize(
    "CREATE TABLE authors (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("create"),
    Keyword("table"),
    Ident("authors"),
    LParen,
    Ident("id"),
    Keyword("bigserial"),
    Keyword("primary"),
    Keyword("key"),
    Comma,
    Ident("name"),
    Ident("TEXT"),
    Keyword("not"),
    Keyword("null"),
    RParen,
    Semicolon,
  ])
}

// --- String literal tests ---

pub fn string_literal_test() {
  lexer.tokenize("SELECT 'hello world'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("hello world")])
}

pub fn escaped_single_quote_test() {
  lexer.tokenize("SELECT 'it''s'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("it's")])
}

pub fn dollar_quoted_string_postgresql_test() {
  lexer.tokenize("SELECT $$hello 'world' -- not comment$$", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    StringLit("hello 'world' -- not comment"),
  ])
}

pub fn tagged_dollar_quoted_string_postgresql_test() {
  lexer.tokenize("SELECT $tag$hello $1 world$tag$, id", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    StringLit("hello $1 world"),
    Comma,
    Ident("id"),
  ])
}

pub fn nested_dollar_quoted_tags_postgresql_test() {
  lexer.tokenize(
    "SELECT $outer$contains $$inner$$ text$outer$",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("select"),
    StringLit("contains $$inner$$ text"),
  ])
}

// --- Comment tests ---

pub fn line_comment_stripped_test() {
  lexer.tokenize(
    "SELECT id -- this is a comment\nFROM authors",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("select"),
    Ident("id"),
    Keyword("from"),
    Ident("authors"),
  ])
}

pub fn block_comment_stripped_test() {
  lexer.tokenize("SELECT /* comment */ id FROM authors", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Ident("id"),
    Keyword("from"),
    Ident("authors"),
  ])
}

pub fn nested_block_comment_test() {
  lexer.tokenize(
    "SELECT /* outer /* inner */ still outer */ id FROM authors",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("select"),
    Ident("id"),
    Keyword("from"),
    Ident("authors"),
  ])
}

pub fn mysql_hash_comment_test() {
  lexer.tokenize("SELECT id # comment\nFROM users", model.MySQL)
  |> should.equal([
    Keyword("select"),
    Ident("id"),
    Keyword("from"),
    Ident("users"),
  ])
}

// --- Quoted identifier tests ---

pub fn double_quoted_identifier_postgresql_test() {
  lexer.tokenize("SELECT \"user\" FROM \"my table\"", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    QuotedIdent("user"),
    Keyword("from"),
    QuotedIdent("my table"),
  ])
}

pub fn backtick_identifier_mysql_test() {
  lexer.tokenize("SELECT `order` FROM `my table`", model.MySQL)
  |> should.equal([
    Keyword("select"),
    QuotedIdent("order"),
    Keyword("from"),
    QuotedIdent("my table"),
  ])
}

pub fn bracket_identifier_sqlite_test() {
  lexer.tokenize("SELECT [order] FROM [my table]", model.SQLite)
  |> should.equal([
    Keyword("select"),
    QuotedIdent("order"),
    Keyword("from"),
    QuotedIdent("my table"),
  ])
}

pub fn double_quoted_identifier_with_escaped_quote_postgresql_test() {
  lexer.tokenize("SELECT \"foo\"\"bar\"", model.PostgreSQL)
  |> should.equal([Keyword("select"), QuotedIdent("foo\"bar")])
}

pub fn double_quoted_identifier_with_escaped_quote_sqlite_test() {
  lexer.tokenize("SELECT \"foo\"\"bar\"", model.SQLite)
  |> should.equal([Keyword("select"), QuotedIdent("foo\"bar")])
}

pub fn backtick_identifier_with_escaped_backtick_mysql_test() {
  lexer.tokenize("SELECT `foo``bar`", model.MySQL)
  |> should.equal([Keyword("select"), QuotedIdent("foo`bar")])
}

pub fn mysql_double_quoted_string_with_escaped_quote_test() {
  lexer.tokenize("SELECT \"hi\"\"there\"", model.MySQL)
  |> should.equal([Keyword("select"), StringLit("hi\"there")])
}

// Bracket identifiers in SQLite have no escape mechanism for ];
// the first ] closes the identifier and any trailing ] is parsed separately.
pub fn bracket_identifier_no_escape_sqlite_test() {
  let tokens = lexer.tokenize("SELECT [a]]b]", model.SQLite)
  case tokens {
    [Keyword("select"), QuotedIdent("a"), ..] -> Nil
    _ -> panic as "bracket identifier should terminate at first ]"
  }
}

pub fn rollup_cube_sets_are_keywords_test() {
  lexer.tokenize("GROUP BY ROLLUP, CUBE, GROUPING SETS", model.PostgreSQL)
  |> should.equal([
    Keyword("group"),
    Keyword("by"),
    Keyword("rollup"),
    Comma,
    Keyword("cube"),
    Comma,
    Ident("GROUPING"),
    Keyword("sets"),
  ])
}

// --- JSON / Array operator tokenization (PostgreSQL) ---

pub fn json_arrow_extract_operators_test() {
  lexer.tokenize("data->'a' #> '{b,c}' #>> '{d}'", model.PostgreSQL)
  |> should.equal([
    Ident("data"),
    Operator("->"),
    StringLit("a"),
    Operator("#>"),
    StringLit("{b,c}"),
    Operator("#>>"),
    StringLit("{d}"),
  ])
}

pub fn json_containment_operators_test() {
  lexer.tokenize("a @> b AND c <@ d", model.PostgreSQL)
  |> should.equal([
    Ident("a"),
    Operator("@>"),
    Ident("b"),
    Keyword("and"),
    Ident("c"),
    Operator("<@"),
    Ident("d"),
  ])
}

pub fn jsonb_key_existence_operators_test() {
  lexer.tokenize("a ?| b AND c ?& d", model.PostgreSQL)
  |> should.equal([
    Ident("a"),
    Operator("?|"),
    Ident("b"),
    Keyword("and"),
    Ident("c"),
    Operator("?&"),
    Ident("d"),
  ])
}

pub fn array_overlap_operator_test() {
  lexer.tokenize("a && b", model.PostgreSQL)
  |> should.equal([Ident("a"), Operator("&&"), Ident("b")])
}

// `?` alone must still tokenize as a SQLite/MySQL placeholder when no
// `|` or `&` follows.
pub fn bare_question_mark_still_placeholder_test() {
  lexer.tokenize("WHERE id = ?", model.SQLite)
  |> should.equal([
    Keyword("where"),
    Ident("id"),
    Operator("="),
    Placeholder("?"),
  ])
}

// --- Prefixed string literals: E'..', U&'..', B'..', X'..', N'..' ---

pub fn pg_escape_string_literal_test() {
  lexer.tokenize("SELECT E'hello'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("hello")])
}

pub fn pg_escape_string_lowercase_e_test() {
  lexer.tokenize("SELECT e'hello'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("hello")])
}

pub fn bit_string_literal_test() {
  lexer.tokenize("SELECT B'1010'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("1010")])
}

pub fn hex_string_literal_test() {
  lexer.tokenize("SELECT X'ff'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("ff")])
}

pub fn unicode_string_literal_test() {
  lexer.tokenize("SELECT U&'\\0061'", model.PostgreSQL)
  |> should.equal([Keyword("select"), StringLit("\\0061")])
}

pub fn national_string_literal_test() {
  // SQL standard N'...' for national character strings.
  lexer.tokenize("SELECT N'hello'", model.MySQL)
  |> should.equal([Keyword("select"), StringLit("hello")])
}

// `Email` (Ident starting with E) must still tokenize as Ident, not as
// an E-prefixed string.
pub fn ident_starting_with_e_is_still_ident_test() {
  lexer.tokenize("SELECT Email FROM users", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Ident("Email"),
    Keyword("from"),
    Ident("users"),
  ])
}

pub fn mysql_hex_literal_0x_test() {
  lexer.tokenize("SELECT 0xFF", model.MySQL)
  |> should.equal([Keyword("select"), NumberLit("0xFF")])
}

pub fn mysql_hex_literal_lowercase_0x_test() {
  lexer.tokenize("SELECT 0xabc", model.MySQL)
  |> should.equal([Keyword("select"), NumberLit("0xabc")])
}

// 0 followed by a non-hex char is still a regular number followed by
// whatever (here, a comma).
pub fn zero_alone_is_number_test() {
  lexer.tokenize("SELECT 0, 1", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    NumberLit("0"),
    Comma,
    NumberLit("1"),
  ])
}

// --- Placeholder tests ---

pub fn postgresql_placeholder_test() {
  lexer.tokenize("WHERE id = $1 AND name = $2", model.PostgreSQL)
  |> should.equal([
    Keyword("where"),
    Ident("id"),
    Operator("="),
    Placeholder("$1"),
    Keyword("and"),
    Ident("name"),
    Operator("="),
    Placeholder("$2"),
  ])
}

pub fn mysql_placeholder_test() {
  lexer.tokenize("WHERE id = ?", model.MySQL)
  |> should.equal([
    Keyword("where"),
    Ident("id"),
    Operator("="),
    Placeholder("?"),
  ])
}

pub fn sqlite_named_placeholder_test() {
  lexer.tokenize("WHERE id = :user_id AND name = @name", model.SQLite)
  |> should.equal([
    Keyword("where"),
    Ident("id"),
    Operator("="),
    Placeholder(":user_id"),
    Keyword("and"),
    Ident("name"),
    Operator("="),
    Placeholder("@name"),
  ])
}

pub fn sqlite_numbered_placeholder_test() {
  lexer.tokenize("WHERE id = ?1", model.SQLite)
  |> should.equal([
    Keyword("where"),
    Ident("id"),
    Operator("="),
    Placeholder("?1"),
  ])
}

// --- Operator tests ---

pub fn postgresql_typecast_test() {
  lexer.tokenize("$1::int", model.PostgreSQL)
  |> should.equal([Placeholder("$1"), Operator("::"), Ident("int")])
}

pub fn comparison_operators_test() {
  lexer.tokenize("a >= b AND c <> d", model.PostgreSQL)
  |> should.equal([
    Ident("a"),
    Operator(">="),
    Ident("b"),
    Keyword("and"),
    Ident("c"),
    Operator("<>"),
    Ident("d"),
  ])
}

pub fn json_operators_test() {
  lexer.tokenize("data->>'key'", model.PostgreSQL)
  |> should.equal([
    Ident("data"),
    Operator("->>"),
    StringLit("key"),
  ])
}

// --- Number tests ---

pub fn integer_literal_test() {
  lexer.tokenize("SELECT 42", model.PostgreSQL)
  |> should.equal([Keyword("select"), NumberLit("42")])
}

pub fn float_literal_test() {
  lexer.tokenize("SELECT 3.14", model.PostgreSQL)
  |> should.equal([Keyword("select"), NumberLit("3.14")])
}

// --- Schema-qualified identifier tests ---

pub fn schema_qualified_table_test() {
  lexer.tokenize("SELECT * FROM public.users", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Star,
    Keyword("from"),
    Ident("public"),
    Dot,
    Ident("users"),
  ])
}

// --- Complex SQL tests ---

pub fn semicolon_in_string_literal_test() {
  lexer.tokenize("INSERT INTO t VALUES ('a;b;c')", model.PostgreSQL)
  |> should.equal([
    Keyword("insert"),
    Keyword("into"),
    Ident("t"),
    Keyword("values"),
    LParen,
    StringLit("a;b;c"),
    RParen,
  ])
}

pub fn comment_in_create_table_test() {
  lexer.tokenize(
    "CREATE TABLE t (\n  id INT, -- primary key\n  name TEXT\n);",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("create"),
    Keyword("table"),
    Ident("t"),
    LParen,
    Ident("id"),
    Ident("INT"),
    Comma,
    Ident("name"),
    Ident("TEXT"),
    RParen,
    Semicolon,
  ])
}

pub fn subquery_tokens_test() {
  lexer.tokenize(
    "SELECT * FROM (SELECT id FROM users) AS sub",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("select"),
    Star,
    Keyword("from"),
    LParen,
    Keyword("select"),
    Ident("id"),
    Keyword("from"),
    Ident("users"),
    RParen,
    Keyword("as"),
    Ident("sub"),
  ])
}

pub fn create_temporary_table_test() {
  lexer.tokenize("CREATE TEMPORARY TABLE tmp (id INT)", model.PostgreSQL)
  |> should.equal([
    Keyword("create"),
    Keyword("temporary"),
    Keyword("table"),
    Ident("tmp"),
    LParen,
    Ident("id"),
    Ident("INT"),
    RParen,
  ])
}

pub fn enum_with_escaped_quotes_test() {
  // `type` is no longer reserved as a keyword (#479) so it lexes as
  // a case-preserving Ident — `CREATE TYPE` (uppercase) tokenises
  // as `Keyword("create"), Ident("TYPE")`. Schema parsing handles
  // the case insensitivity downstream.
  lexer.tokenize(
    "CREATE TYPE status AS ENUM ('it''s', 'ok');",
    model.PostgreSQL,
  )
  |> should.equal([
    Keyword("create"),
    Ident("TYPE"),
    Ident("status"),
    Keyword("as"),
    Keyword("enum"),
    LParen,
    StringLit("it's"),
    Comma,
    StringLit("ok"),
    RParen,
    Semicolon,
  ])
}

pub fn mysql_double_quote_as_string_test() {
  lexer.tokenize("SELECT \"hello\"", model.MySQL)
  |> should.equal([Keyword("select"), StringLit("hello")])
}

pub fn table_alias_tokens_test() {
  lexer.tokenize("SELECT u.name FROM users u", model.PostgreSQL)
  |> should.equal([
    Keyword("select"),
    Ident("u"),
    Dot,
    Ident("name"),
    Keyword("from"),
    Ident("users"),
    Ident("u"),
  ])
}

// --- Malformed input robustness ---
// These tests verify the lexer does not panic on malformed SQL. Exact
// tokenization of invalid input is not specified; we only require that
// tokenize returns a list without crashing.

pub fn empty_input_test() {
  lexer.tokenize("", model.PostgreSQL) |> should.equal([])
}

pub fn whitespace_only_input_test() {
  lexer.tokenize("   \n\t  ", model.PostgreSQL) |> should.equal([])
}

pub fn unterminated_string_literal_does_not_panic_test() {
  let tokens = lexer.tokenize("SELECT 'unclosed", model.PostgreSQL)
  tokens |> list.is_empty |> should.be_false
}

pub fn unterminated_block_comment_does_not_panic_test() {
  let tokens = lexer.tokenize("SELECT 1 /* no end", model.PostgreSQL)
  tokens |> list.is_empty |> should.be_false
}

pub fn unterminated_dollar_quoted_string_does_not_panic_test() {
  let tokens = lexer.tokenize("SELECT $$no end", model.PostgreSQL)
  tokens |> list.is_empty |> should.be_false
}

pub fn only_operators_input_does_not_panic_test() {
  let tokens = lexer.tokenize("= > < <= >= <>", model.PostgreSQL)
  tokens |> list.is_empty |> should.be_false
}

// --- Issue #513: keyword case consistency ---

/// `INSERT OR IGNORE / ABORT / FAIL` previously rendered as `insert
/// or IGNORE / ABORT / FAIL` because `IGNORE` / `ABORT` / `FAIL`
/// were not in the keyword list and survived as preserved-case
/// `Ident`s while their `INSERT` / `OR` / `INTO` siblings lowercased
/// via the `Keyword` token path. They are now keywords and lowercase
/// uniformly with the rest of the rendered SQL.
pub fn insert_or_ignore_renders_consistently_lowercased_test() {
  let opts =
    lexer.TokenRenderOptions(
      uppercase_keywords: False,
      preserve_quotes: True,
      engine: option.None,
    )
  let rendered =
    "INSERT OR IGNORE INTO post_tags (post_id, tag) VALUES (?, ?)"
    |> lexer.tokenize(model.SQLite)
    |> lexer.tokens_to_string(opts)
  rendered
  |> should.equal("insert or ignore into post_tags(post_id, tag) values(?, ?)")
}

pub fn insert_or_abort_renders_consistently_lowercased_test() {
  let opts =
    lexer.TokenRenderOptions(
      uppercase_keywords: False,
      preserve_quotes: True,
      engine: option.None,
    )
  let rendered =
    "INSERT OR ABORT INTO t VALUES (1)"
    |> lexer.tokenize(model.SQLite)
    |> lexer.tokens_to_string(opts)
  rendered |> should.equal("insert or abort into t values(1)")
}

pub fn insert_or_fail_renders_consistently_lowercased_test() {
  let opts =
    lexer.TokenRenderOptions(
      uppercase_keywords: False,
      preserve_quotes: True,
      engine: option.None,
    )
  let rendered =
    "INSERT OR FAIL INTO t VALUES (1)"
    |> lexer.tokenize(model.SQLite)
    |> lexer.tokens_to_string(opts)
  rendered |> should.equal("insert or fail into t values(1)")
}
