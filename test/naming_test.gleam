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
  let ctx = naming.new()
  naming.to_snake_case(ctx, "GetV2Author") |> should.equal("get_v_2_author")
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

pub fn singularize_compound_table_names_test() {
  let ctx = naming.new()
  // blog_posts → singularize("blog_posts") → "blog_post" → PascalCase → "BlogPost"
  naming.to_pascal_case(ctx, naming.singularize("blog_posts"))
  |> should.equal("BlogPost")
  naming.to_pascal_case(ctx, naming.singularize("user_roles"))
  |> should.equal("UserRole")
}
