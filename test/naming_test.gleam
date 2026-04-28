import gleeunit
import gleeunit/should
import sqlode/naming

pub fn main() {
  gleeunit.main()
}

// to_pascal_case tests

pub fn pascal_case_from_snake_case_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "get_author") |> should.equal("GetAuthor")
}

pub fn pascal_case_from_camel_case_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "getAuthor") |> should.equal("GetAuthor")
}

pub fn pascal_case_from_all_caps_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "HTTP") |> should.equal("HTTP")
}

pub fn pascal_case_with_numbers_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "get_v2_author") |> should.equal("GetV2Author")
}

pub fn pascal_case_single_word_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "author") |> should.equal("Author")
}

pub fn pascal_case_already_pascal_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "GetAuthor") |> should.equal("GetAuthor")
}

pub fn pascal_case_with_consecutive_underscores_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "get__author") |> should.equal("GetAuthor")
}

// to_snake_case tests

pub fn snake_case_from_pascal_case_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "GetAuthor") |> should.equal("get_author")
}

pub fn snake_case_from_camel_case_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "getAuthor") |> should.equal("get_author")
}

pub fn snake_case_already_snake_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "get_author") |> should.equal("get_author")
}

pub fn snake_case_from_all_caps_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "HTTP") |> should.equal("http")
}

pub fn snake_case_with_numbers_test() {
  // Trailing-digit suffixes are now glued to the preceding letter
  // run (#480): "V2" stays as one word, so "GetV2Author" splits as
  // ["Get", "V2", "Author"] → "get_v2_author". Previously the
  // letter→digit boundary was a split point, producing the
  // misleading "get_v_2_author".
  let ctx = naming.new()
  naming.to_snake_case(ctx, "GetV2Author") |> should.equal("get_v2_author")
}

// --- Letter+digit suffix preservation (#480) ---
//
// Hash / encoding / version suffixes like sha256, utf8, base64,
// oauth2, ipv4, s3, md5, http2 are conventionally one word. The
// snake_case conversion must NOT insert an underscore between the
// letter run and the trailing digit run.

pub fn snake_case_keeps_sha256_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "sha256") |> should.equal("sha256")
}

pub fn snake_case_keeps_utf8_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "utf8") |> should.equal("utf8")
}

pub fn snake_case_keeps_base64_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "base64") |> should.equal("base64")
}

pub fn snake_case_keeps_oauth2_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "oauth2") |> should.equal("oauth2")
}

pub fn snake_case_keeps_ipv4_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "ipv4") |> should.equal("ipv4")
}

pub fn snake_case_keeps_md5_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "md5") |> should.equal("md5")
}

pub fn snake_case_keeps_s3_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "s3") |> should.equal("s3")
}

pub fn snake_case_keeps_http2_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "http2") |> should.equal("http2")
}

pub fn snake_case_keeps_allcaps_with_digit_suffix_intact_test() {
  // ALLCAPS-with-digit-suffix follows the same rule: "ID2" is one
  // word, not "ID" + "2".
  let ctx = naming.new()
  naming.to_snake_case(ctx, "USER_ID2") |> should.equal("user_id2")
}

pub fn snake_case_splits_digit_then_letter_boundary_test() {
  // Digit→letter direction stays a split point — the convention
  // is asymmetric. "256sha" reads as ["256", "sha"], not "256sha".
  let ctx = naming.new()
  naming.to_snake_case(ctx, "256sha") |> should.equal("256_sha")
}

pub fn snake_case_keeps_pascal_case_with_digit_suffix_intact_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "Sha256Hash") |> should.equal("sha256_hash")
}

pub fn snake_case_reserved_word_escaped_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "type") |> should.equal("type_")
  naming.to_snake_case(ctx, "let") |> should.equal("let_")
  naming.to_snake_case(ctx, "case") |> should.equal("case_")
  naming.to_snake_case(ctx, "fn") |> should.equal("fn_")
  naming.to_snake_case(ctx, "pub") |> should.equal("pub_")
  naming.to_snake_case(ctx, "import") |> should.equal("import_")
}

pub fn snake_case_non_reserved_word_not_escaped_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "name") |> should.equal("name")
  naming.to_snake_case(ctx, "author") |> should.equal("author")
}

// normalize_identifier tests

pub fn normalize_strips_double_quotes_test() {
  naming.normalize_identifier("\"authors\"") |> should.equal("authors")
}

pub fn normalize_strips_backticks_test() {
  naming.normalize_identifier("`authors`") |> should.equal("authors")
}

pub fn normalize_strips_square_brackets_test() {
  naming.normalize_identifier("[authors]") |> should.equal("authors")
}

pub fn normalize_extracts_last_dot_segment_test() {
  naming.normalize_identifier("public.authors") |> should.equal("authors")
}

pub fn normalize_lowercases_test() {
  naming.normalize_identifier("Authors") |> should.equal("authors")
}

pub fn normalize_trims_whitespace_test() {
  naming.normalize_identifier("  authors  ") |> should.equal("authors")
}

pub fn normalize_dot_then_quotes_test() {
  naming.normalize_identifier("public.\"Authors\"")
  |> should.equal("authors")
}

// singularize tests

pub fn singularize_regular_plural_test() {
  naming.singularize("authors") |> should.equal("author")
  naming.singularize("users") |> should.equal("user")
  naming.singularize("posts") |> should.equal("post")
}

pub fn singularize_ies_test() {
  naming.singularize("categories") |> should.equal("category")
  naming.singularize("companies") |> should.equal("company")
}

pub fn singularize_es_test() {
  naming.singularize("boxes") |> should.equal("box")
  naming.singularize("watches") |> should.equal("watch")
  naming.singularize("classes") |> should.equal("class")
  naming.singularize("dishes") |> should.equal("dish")
  naming.singularize("buzzes") |> should.equal("buzz")
}

pub fn singularize_ves_test() {
  naming.singularize("wolves") |> should.equal("wolf")
}

pub fn singularize_already_singular_test() {
  naming.singularize("author") |> should.equal("author")
  naming.singularize("status") |> should.equal("status")
  naming.singularize("address") |> should.equal("address")
}

pub fn singularize_ss_unchanged_test() {
  naming.singularize("boss") |> should.equal("boss")
}

pub fn singularize_irregular_test() {
  naming.singularize("people") |> should.equal("person")
  naming.singularize("children") |> should.equal("child")
}

/// Issue #514: Latin-style plurals (`media`, `data`, `criteria`, …)
/// are mass nouns or already-singular in modern English usage. The
/// formally correct singulars (`Medium`, `Datum`, `Criterion`)
/// surprise every Gleam user picking these as table names. They are
/// now treated as already-singular so a `media` table generates a
/// `Media` type rather than `Medium`.
pub fn singularize_latin_mass_nouns_treated_as_singular_test() {
  naming.singularize("media") |> should.equal("media")
  naming.singularize("data") |> should.equal("data")
  naming.singularize("criteria") |> should.equal("criteria")
  naming.singularize("agenda") |> should.equal("agenda")
  naming.singularize("schemata") |> should.equal("schemata")
  naming.singularize("bacteria") |> should.equal("bacteria")
  naming.singularize("phenomena") |> should.equal("phenomena")
}

/// And the resulting type name when fed through the table-name
/// pipeline is the modern-English-friendly form (no surprise `Medium`).
pub fn table_type_name_for_media_table_is_media_test() {
  let ctx = naming.new()
  naming.table_type_name(ctx, "media", False) |> should.equal("Media")
  naming.table_type_name(ctx, "data", False) |> should.equal("Data")
}

// Edge case tests — empty strings, single chars, unicode, numbers only

pub fn pascal_case_empty_string_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "") |> should.equal("")
}

pub fn snake_case_empty_string_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "") |> should.equal("")
}

pub fn pascal_case_only_underscores_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "___") |> should.equal("")
}

pub fn snake_case_only_underscores_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "___") |> should.equal("")
}

pub fn pascal_case_only_numbers_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "123") |> should.equal("123")
}

pub fn snake_case_only_numbers_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "123") |> should.equal("123")
}

pub fn pascal_case_single_lower_char_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "a") |> should.equal("A")
}

pub fn pascal_case_single_upper_char_test() {
  let ctx = naming.new()
  naming.to_pascal_case(ctx, "A") |> should.equal("A")
}

pub fn snake_case_single_upper_char_test() {
  let ctx = naming.new()
  naming.to_snake_case(ctx, "A") |> should.equal("a")
}

pub fn normalize_identifier_empty_test() {
  naming.normalize_identifier("") |> should.equal("")
}

pub fn normalize_identifier_whitespace_only_test() {
  naming.normalize_identifier("   ") |> should.equal("")
}

pub fn singularize_empty_test() {
  naming.singularize("") |> should.equal("")
}

pub fn singularize_single_char_test() {
  naming.singularize("a") |> should.equal("a")
}

pub fn normalize_identifier_unicode_test() {
  // Japanese column name in quoted identifier
  naming.normalize_identifier("\"著者\"") |> should.equal("著者")
}

pub fn singularize_unicode_preserves_input_test() {
  // Non-ASCII input that doesn't match any pluralization rule stays as-is
  naming.singularize("著者") |> should.equal("著者")
}

pub fn singularize_compound_table_names_test() {
  let ctx = naming.new()
  // blog_posts → singularize("blog_posts") → "blog_post" → PascalCase → "BlogPost"
  naming.to_pascal_case(ctx, naming.singularize("blog_posts"))
  |> should.equal("BlogPost")
  naming.to_pascal_case(ctx, naming.singularize("user_roles"))
  |> should.equal("UserRole")
}
