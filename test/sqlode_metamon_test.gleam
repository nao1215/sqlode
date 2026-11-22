//// metamon property tests for the `sqlode/runtime` markers and
//// `sqlode/internal/naming`, so a change to the word splitter surfaces
//// here instead of in the generated code.

import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import sqlode/internal/naming
import sqlode/runtime

// ---------- runtime markers ----------

pub fn param_and_slice_markers_have_distinct_prefixes_test() -> Nil {
  metamon.forall(generator.int(range.constant(1, 50)), fn(index) {
    runtime.param_marker(index) != runtime.slice_marker(index)
  })
}

// ---------- naming case converters ----------

fn word_generator() -> generator.Generator(String) {
  generator.string_alphanumeric(range.constant(1, 8))
}

pub fn to_pascal_case_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    let ctx = naming.new()
    let once = naming.to_pascal_case(ctx, input)
    let twice = naming.to_pascal_case(ctx, once)
    once == twice
  })
}

pub fn to_pascal_case_drops_separators_test() -> Nil {
  metamon.forall(
    generator.list_of(word_generator(), range.constant(1, 4)),
    fn(words) {
      let ctx = naming.new()
      let snake_input = string.join(words, "_")
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let snake = naming.to_pascal_case(ctx, snake_input)
      let kebab = naming.to_pascal_case(ctx, kebab_input)
      let dot = naming.to_pascal_case(ctx, dot_input)
      !string.contains(snake, "_")
      && !string.contains(kebab, "-")
      && !string.contains(dot, ".")
    },
  )
}

pub fn to_snake_case_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    let ctx = naming.new()
    let once = naming.to_snake_case(ctx, input)
    let twice = naming.to_snake_case(ctx, once)
    once == twice
  })
}

pub fn to_snake_case_has_no_uppercase_test() -> Nil {
  metamon.forall(generator.string_alpha(range.constant(0, 8)), fn(input) {
    let ctx = naming.new()
    let result = naming.to_snake_case(ctx, input)
    result == string.lowercase(result)
  })
}

pub fn to_snake_case_drops_separators_test() -> Nil {
  metamon.forall(
    generator.list_of(
      generator.string_alpha(range.constant(1, 6)),
      range.constant(1, 3),
    ),
    fn(words) {
      let ctx = naming.new()
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let kebab = naming.to_snake_case(ctx, kebab_input)
      let dot = naming.to_snake_case(ctx, dot_input)
      !string.contains(kebab, "-") && !string.contains(dot, ".")
    },
  )
}

// ---------- naming.normalize_identifier ----------

pub fn normalize_identifier_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    naming.normalize_identifier(naming.normalize_identifier(input))
    == naming.normalize_identifier(input)
  })
}

pub fn normalize_identifier_lowercases_alpha_test() -> Nil {
  metamon.forall(generator.string_alpha(range.constant(1, 8)), fn(input) {
    let result = naming.normalize_identifier(input)
    result == string.lowercase(result)
  })
}

// ---------- naming.singularize ----------

pub fn singularize_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    naming.singularize(naming.singularize(input)) == naming.singularize(input)
  })
}
