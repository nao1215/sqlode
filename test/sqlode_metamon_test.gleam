//// metamon property tests for `sqlode/runtime` and
//// `sqlode/internal/naming`. Pin the algebraic invariants the
//// public surface is documented to hold so a future refactor of
//// the value encoders or the regex-driven word splitter surfaces
//// a regression here instead of cascading into the generated
//// code.

import gleam/list
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import sqlode/internal/naming
import sqlode/runtime

// ---------- runtime.Value encoders ----------

pub fn null_returns_sql_null_test() -> Nil {
  assert runtime.null() == runtime.Null
}

pub fn string_round_trips_through_sql_string_test() -> Nil {
  metamon.forall(
    generator.string_alphanumeric(range.constant(0, 16)),
    fn(value) { runtime.string(value) == runtime.String(value) },
  )
}

pub fn int_round_trips_through_sql_int_test() -> Nil {
  metamon.forall(generator.int(range.constant(-1000, 1000)), fn(value) {
    runtime.int(value) == runtime.Int(value)
  })
}

pub fn bool_round_trips_through_sql_bool_test() -> Nil {
  metamon.forall(generator.bool(), fn(value) {
    runtime.bool(value) == runtime.Bool(value)
  })
}

pub fn bytes_round_trips_through_sql_bytes_test() -> Nil {
  metamon.forall(generator.bit_array(range.constant(0, 32)), fn(value) {
    runtime.bytes(value) == runtime.Bytes(value)
  })
}

pub fn array_preserves_length_test() -> Nil {
  metamon.forall(
    generator.list_of(
      generator.int(range.constant(-50, 50)),
      range.constant(0, 6),
    ),
    fn(values) {
      let encoded = list.map(values, runtime.int)
      case runtime.array(encoded) {
        runtime.Array(items) -> list.length(items) == list.length(values)
        _ -> False
      }
    },
  )
}

// ---------- runtime.param_marker_checked / slice_marker_checked ----------

pub fn param_marker_checked_accepts_positive_indices_test() -> Nil {
  metamon.forall(generator.int(range.constant(1, 100)), fn(index) {
    case runtime.param_marker_checked(index) {
      Ok(marker) -> string.starts_with(marker, "__sqlode_param_")
      Error(_) -> False
    }
  })
}

pub fn param_marker_checked_rejects_zero_and_negative_test() -> Nil {
  metamon.forall(generator.int(range.constant(-50, 0)), fn(index) {
    case runtime.param_marker_checked(index) {
      Error(runtime.MarkerIndexNonPositive(index: actual)) -> actual == index
      _ -> False
    }
  })
}

pub fn slice_marker_checked_accepts_positive_indices_test() -> Nil {
  metamon.forall(generator.int(range.constant(1, 100)), fn(index) {
    case runtime.slice_marker_checked(index) {
      Ok(marker) -> string.starts_with(marker, "__sqlode_slice_")
      Error(_) -> False
    }
  })
}

pub fn slice_marker_checked_rejects_zero_and_negative_test() -> Nil {
  metamon.forall(generator.int(range.constant(-50, 0)), fn(index) {
    case runtime.slice_marker_checked(index) {
      Error(runtime.MarkerIndexNonPositive(index: actual)) -> actual == index
      _ -> False
    }
  })
}

pub fn param_and_slice_markers_have_distinct_prefixes_test() -> Nil {
  metamon.forall(generator.int(range.constant(1, 50)), fn(index) {
    let assert Ok(param) = runtime.param_marker_checked(index)
    let assert Ok(slice) = runtime.slice_marker_checked(index)
    param != slice
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
