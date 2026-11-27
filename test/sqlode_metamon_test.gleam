//// metamon property tests for the `sqlode/runtime` markers and
//// `sqlode/internal/naming`, so a change to the word splitter surfaces
//// here instead of in the generated code.

import gleam/string
import metamon
import metamon/generator
import sqlode/internal/naming
import sqlode/runtime

// ---------- runtime markers ----------

pub fn param_and_slice_markers_have_distinct_prefixes_test() -> Nil {
  metamon.forall(generator.int(generator.range(from: 1, to: 50)), fn(index) {
    assert runtime.param_marker(index) != runtime.slice_marker(index)
  })
}

// ---------- naming case converters ----------

fn word_generator() -> generator.Generator(String) {
  generator.string(
    of: generator.Alphanumeric,
    length: generator.range(from: 1, to: 8),
  )
}

pub fn to_pascal_case_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    let ctx = naming.new()
    let once = naming.to_pascal_case(ctx, input)
    let twice = naming.to_pascal_case(ctx, once)
    assert once == twice
  })
}

pub fn to_pascal_case_drops_separators_test() -> Nil {
  metamon.forall(
    generator.list_of(word_generator(), length: generator.range(from: 1, to: 4)),
    fn(words) {
      let ctx = naming.new()
      let snake_input = string.join(words, "_")
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let snake = naming.to_pascal_case(ctx, snake_input)
      let kebab = naming.to_pascal_case(ctx, kebab_input)
      let dot = naming.to_pascal_case(ctx, dot_input)
      assert !string.contains(snake, "_")
      assert !string.contains(kebab, "-")
      assert !string.contains(dot, ".")
    },
  )
}

pub fn to_snake_case_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    let ctx = naming.new()
    let once = naming.to_snake_case(ctx, input)
    let twice = naming.to_snake_case(ctx, once)
    assert once == twice
  })
}

pub fn to_snake_case_has_no_uppercase_test() -> Nil {
  metamon.forall(
    generator.string(
      of: generator.Alphabetic,
      length: generator.range(from: 0, to: 8),
    ),
    fn(input) {
      let ctx = naming.new()
      let result = naming.to_snake_case(ctx, input)
      assert result == string.lowercase(result)
    },
  )
}

pub fn to_snake_case_drops_separators_test() -> Nil {
  metamon.forall(
    generator.list_of(
      generator.string(
        of: generator.Alphabetic,
        length: generator.range(from: 1, to: 6),
      ),
      length: generator.range(from: 1, to: 3),
    ),
    fn(words) {
      let ctx = naming.new()
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let kebab = naming.to_snake_case(ctx, kebab_input)
      let dot = naming.to_snake_case(ctx, dot_input)
      assert !string.contains(kebab, "-")
      assert !string.contains(dot, ".")
    },
  )
}

// ---------- naming.normalize_identifier ----------

pub fn normalize_identifier_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    assert naming.normalize_identifier(naming.normalize_identifier(input))
      == naming.normalize_identifier(input)
  })
}

pub fn normalize_identifier_lowercases_alpha_test() -> Nil {
  metamon.forall(
    generator.string(
      of: generator.Alphabetic,
      length: generator.range(from: 1, to: 8),
    ),
    fn(input) {
      let result = naming.normalize_identifier(input)
      assert result == string.lowercase(result)
    },
  )
}

// ---------- naming.singularize ----------

pub fn singularize_is_idempotent_test() -> Nil {
  metamon.forall(word_generator(), fn(input) {
    assert naming.singularize(naming.singularize(input))
      == naming.singularize(input)
  })
}
