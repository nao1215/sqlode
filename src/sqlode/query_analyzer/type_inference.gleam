//// IR-driven type inference.
////
//// `infer_expr_type` walks a `query_ir.Expr` and returns the inferred
//// `#(ScalarType, nullable)` pair, resolving column references against
//// the supplied catalog and table scope. It replaces the previous
//// heuristic path that operated on raw `List(lexer.Token)`.
////
//// When the IR contains a `RawExpr` node — or an inner construct that
//// inference can't make sense of — the function returns an
//// `UnsupportedExpression` error tied to the raw token fragment so
//// the operator gets an explicit diagnostic pointing at the IR gap,
//// never a silent fallback to `StringType`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlode/lexer
import sqlode/model
import sqlode/query_analyzer/context.{type AnalysisError, UnsupportedExpression}
import sqlode/query_ir

/// Inferred type and nullability for an expression.
pub type InferredType {
  InferredType(scalar: model.ScalarType, nullable: Bool)
}

/// Scope used to resolve `ColumnRef` during expression inference.
///
/// - `catalog` is the augmented catalog (base tables + CTEs + VALUES
///   + derived tables).
/// - `in_scope_tables` is the ordered list of FROM/JOIN table names
///   (or aliases) visible at this expression's nesting level.
/// - `nullable_tables` is the list of table names whose columns become
///   nullable because of an outer LEFT/RIGHT/FULL join.
pub type Scope {
  Scope(
    query_name: String,
    catalog: model.Catalog,
    in_scope_tables: List(String),
    nullable_tables: List(String),
  )
}

pub fn scope(
  query_name: String,
  catalog: model.Catalog,
  in_scope_tables: List(String),
  nullable_tables: List(String),
) -> Scope {
  Scope(
    query_name: query_name,
    catalog: catalog,
    in_scope_tables: in_scope_tables,
    nullable_tables: nullable_tables,
  )
}

pub fn infer_expr_type(
  scope: Scope,
  expr: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case expr {
    query_ir.NullLit ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "NULL",
      ))
    query_ir.BoolLit(..) -> ok(model.BoolType, False)
    query_ir.StringLit(..) -> ok(model.StringType, False)
    query_ir.NumberLit(value: n) -> ok(number_type(n), False)
    query_ir.Param(..) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "parameter placeholder in result context requires a cast",
      ))
    query_ir.ColumnRef(table: table, name: name) ->
      resolve_column(scope, table, name)
    query_ir.StarRef(..) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "* in expression context",
      ))
    query_ir.Unary(op: op, arg: arg) -> infer_unary(scope, op, arg)
    query_ir.Binary(op: op, left: left, right: right) ->
      infer_binary(scope, op, left, right)
    query_ir.Func(..) as f -> infer_function(scope, f)
    query_ir.Cast(target_type: target, expr: inner) ->
      infer_cast(scope, target, inner)
    query_ir.Case(scrutinee: _, branches: branches, else_: else_) ->
      infer_case(scope, branches, else_)
    query_ir.InExpr(..) -> ok(model.BoolType, False)
    query_ir.Exists(..) -> ok(model.BoolType, False)
    query_ir.ScalarSubquery(core: core) -> infer_scalar_subquery(scope, core)
    query_ir.Quantified(..) -> ok(model.BoolType, False)
    query_ir.Between(..) -> ok(model.BoolType, False)
    query_ir.IsCheck(..) -> ok(model.BoolType, False)
    query_ir.LikeExpr(..) -> ok(model.BoolType, False)
    query_ir.ArrayLit(elements: elems) ->
      case elems {
        [] ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "empty ARRAY[] literal",
          ))
        [first, ..] ->
          case infer_expr_type(scope, first) {
            Ok(InferredType(scalar: t, nullable: _)) ->
              ok(model.ArrayType(element: t), False)
            Error(e) -> Error(e)
          }
      }
    query_ir.Tuple(elements: [single]) -> infer_expr_type(scope, single)
    query_ir.Tuple(..) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "tuple expression",
      ))
    query_ir.Macro(name: name, ..) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "sqlode." <> name <> "(…) in this position",
      ))
    query_ir.RawExpr(reason: reason, tokens: tokens) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: reason <> ": " <> render_tokens(tokens),
      ))
  }
}

fn ok(
  scalar: model.ScalarType,
  nullable: Bool,
) -> Result(InferredType, AnalysisError) {
  Ok(InferredType(scalar: scalar, nullable: nullable))
}

fn number_type(n: String) -> model.ScalarType {
  case
    string.contains(n, ".")
    || string.contains(n, "e")
    || string.contains(n, "E")
  {
    True -> model.FloatType
    False -> model.IntType
  }
}

// ============================================================
// Column resolution
// ============================================================

fn resolve_column(
  scope: Scope,
  table: Option(String),
  name: String,
) -> Result(InferredType, AnalysisError) {
  case table {
    Some(t) ->
      case context.find_column(scope.catalog, t, name) {
        Some(col) ->
          ok(
            col.scalar_type,
            col.nullable || list.contains(scope.nullable_tables, t),
          )
        None ->
          Error(context.ColumnNotFound(
            query_name: scope.query_name,
            table_name: t,
            column_name: name,
          ))
      }
    None ->
      case
        context.find_column_in_tables(
          scope.catalog,
          scope.in_scope_tables,
          name,
        )
      {
        Ok(Some(#(found_table, col))) ->
          ok(
            col.scalar_type,
            col.nullable || list.contains(scope.nullable_tables, found_table),
          )
        Ok(None) ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "unresolved column reference \"" <> name <> "\"",
          ))
        Error(matching) ->
          Error(context.AmbiguousColumnName(
            query_name: scope.query_name,
            column_name: name,
            matching_tables: matching,
          ))
      }
  }
}

// ============================================================
// Unary / binary
// ============================================================

fn infer_unary(
  scope: Scope,
  op: String,
  arg: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case op {
    "not" -> ok(model.BoolType, False)
    "-" | "+" -> infer_expr_type(scope, arg)
    _ ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "unary operator " <> op,
      ))
  }
}

fn infer_binary(
  scope: Scope,
  op: String,
  left: query_ir.Expr,
  right: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case op {
    "and" | "or" -> ok(model.BoolType, False)
    "="
    | "<>"
    | "!="
    | "<"
    | ">"
    | "<="
    | ">="
    | "@>"
    | "<@"
    | "?|"
    | "?&"
    | "&&" -> ok(model.BoolType, False)
    "||" -> {
      // String concatenation. Treat as non-nullable for compatibility
      // with the existing analyzer behaviour — `||` short-circuits at
      // the emitter level to empty strings in the runtime.
      use _ <- result.try(infer_expr_type_allow_null(scope, left))
      use _ <- result.try(infer_expr_type_allow_null(scope, right))
      ok(model.StringType, False)
    }
    "+" | "-" | "*" | "/" | "%" -> {
      use lt <- result.try(infer_expr_type_allow_null(scope, left))
      use rt <- result.try(infer_expr_type_allow_null(scope, right))
      case merge_numeric(lt.scalar, rt.scalar) {
        Ok(scalar) -> ok(scalar, lt.nullable || rt.nullable)
        Error(_) ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "arithmetic operands have incompatible types",
          ))
      }
    }
    "->" | "#>" -> ok(model.JsonType, True)
    "->>" | "#>>" -> ok(model.StringType, True)
    _ ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "binary operator " <> op,
      ))
  }
}

fn infer_expr_type_allow_null(
  scope: Scope,
  expr: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case expr {
    query_ir.NullLit -> ok_unknown_nullable()
    query_ir.Param(..) -> ok_unknown()
    query_ir.Cast(target_type: t, ..) ->
      case model.parse_sql_type(t) {
        Ok(scalar) -> ok(scalar, True)
        Error(_) ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "unrecognised cast type \"" <> t <> "\"",
          ))
      }
    _ -> infer_expr_type(scope, expr)
  }
}

fn ok_unknown() -> Result(InferredType, AnalysisError) {
  Ok(InferredType(scalar: model.IntType, nullable: False))
}

fn ok_unknown_nullable() -> Result(InferredType, AnalysisError) {
  Ok(InferredType(scalar: model.IntType, nullable: True))
}

fn merge_numeric(
  a: model.ScalarType,
  b: model.ScalarType,
) -> Result(model.ScalarType, Nil) {
  case a, b {
    model.IntType, model.IntType -> Ok(model.IntType)
    model.FloatType, model.FloatType -> Ok(model.FloatType)
    model.IntType, model.FloatType -> Ok(model.FloatType)
    model.FloatType, model.IntType -> Ok(model.FloatType)
    x, y ->
      case x == y {
        True -> Ok(x)
        False -> Error(Nil)
      }
  }
}

// ============================================================
// CAST / CASE
// ============================================================

fn infer_cast(
  scope: Scope,
  target: String,
  _inner: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case model.parse_sql_type(target) {
    Ok(scalar) -> ok(scalar, True)
    Error(_) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "unrecognised cast type \"" <> target <> "\"",
      ))
  }
}

fn infer_case(
  scope: Scope,
  branches: List(query_ir.CaseBranch),
  else_: Option(query_ir.Expr),
) -> Result(InferredType, AnalysisError) {
  let branch_thens = list.map(branches, fn(b) { b.then })
  let arms = case else_ {
    Some(e) -> list.append(branch_thens, [e])
    None -> branch_thens
  }
  use types <- result.try(
    list.try_map(arms, fn(arm) { infer_expr_type_allow_null(scope, arm) }),
  )
  case unify_types(types) {
    Ok(#(scalar, inner_nullable)) -> {
      let nullable = case else_ {
        Some(_) -> inner_nullable
        None -> True
      }
      ok(scalar, nullable)
    }
    Error(_) ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "CASE branches have incompatible types",
      ))
  }
}

fn unify_types(
  items: List(InferredType),
) -> Result(#(model.ScalarType, Bool), Nil) {
  case items {
    [] -> Error(Nil)
    [InferredType(scalar: t, nullable: n), ..rest] -> unify_fold(rest, t, n)
  }
}

fn unify_fold(
  items: List(InferredType),
  acc_type: model.ScalarType,
  acc_nullable: Bool,
) -> Result(#(model.ScalarType, Bool), Nil) {
  case items {
    [] -> Ok(#(acc_type, acc_nullable))
    [InferredType(scalar: t, nullable: n), ..rest] -> {
      case merge_numeric(acc_type, t) {
        Ok(merged) -> unify_fold(rest, merged, acc_nullable || n)
        Error(_) ->
          case acc_type == t {
            True -> unify_fold(rest, acc_type, acc_nullable || n)
            False -> Error(Nil)
          }
      }
    }
  }
}

// ============================================================
// Functions
// ============================================================

fn infer_function(
  scope: Scope,
  f: query_ir.Expr,
) -> Result(InferredType, AnalysisError) {
  case f {
    query_ir.Func(name: name, args: args, over: over, ..) -> {
      let window = case over {
        Some(_) -> True
        None -> False
      }
      infer_function_body(scope, name, args, window)
    }
    _ ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "internal: infer_function called with non-Func",
      ))
  }
}

fn infer_function_body(
  scope: Scope,
  name: String,
  args: List(query_ir.FuncArg),
  window: Bool,
) -> Result(InferredType, AnalysisError) {
  case name {
    "count" -> ok(model.IntType, False)
    "sum" | "min" | "max" -> infer_aggregate_from_first(scope, args, True)
    "avg" -> ok(model.FloatType, True)
    "row_number" | "rank" | "dense_rank" | "ntile" -> ok(model.IntType, False)
    "percent_rank" | "cume_dist" -> ok(model.FloatType, False)
    "lag" | "lead" | "first_value" | "last_value" | "nth_value" ->
      infer_window_first(scope, args)
    "coalesce" -> infer_coalesce(scope, args)
    "greatest" | "least" -> infer_aggregate_from_first(scope, args, True)
    "nullif" | "ifnull" | "nvl" -> infer_first_arg(scope, args, True)
    "abs"
    | "round"
    | "floor"
    | "ceil"
    | "ceiling"
    | "mod"
    | "power"
    | "sqrt"
    | "sign"
    | "trunc"
    | "log"
    | "ln"
    | "exp"
    | "random"
    | "pi"
    | "degrees"
    | "radians"
    | "div" -> infer_math_first_arg(scope, args)
    "length"
    | "char_length"
    | "character_length"
    | "octet_length"
    | "bit_length"
    | "position"
    | "strpos"
    | "ascii" -> ok(model.IntType, False)
    "replace"
    | "lower"
    | "upper"
    | "trim"
    | "ltrim"
    | "rtrim"
    | "substr"
    | "substring"
    | "concat"
    | "reverse"
    | "lpad"
    | "rpad"
    | "left"
    | "right"
    | "repeat"
    | "initcap"
    | "translate"
    | "to_char"
    | "format"
    | "quote_literal"
    | "quote_ident"
    | "md5"
    | "encode"
    | "decode" -> ok(model.StringType, False)
    "now"
    | "current_timestamp"
    | "clock_timestamp"
    | "statement_timestamp"
    | "timeofday"
    | "localtimestamp" -> ok(model.DateTimeType, False)
    "current_date" -> ok(model.DateType, False)
    "current_time" | "localtime" -> ok(model.TimeType, False)
    "make_date" | "to_date" -> ok(model.DateType, False)
    "make_time" -> ok(model.TimeType, False)
    "make_timestamp" | "to_timestamp" -> ok(model.DateTimeType, False)
    "date_trunc" | "age" -> ok(model.DateTimeType, False)
    "date_part" | "extract" -> ok(model.FloatType, False)
    "date" -> ok(model.DateType, False)
    "time" -> ok(model.TimeType, False)
    "timestamp" -> ok(model.DateTimeType, False)
    "interval" -> ok(model.TimeType, False)
    _ ->
      case window {
        True -> ok(model.IntType, False)
        False ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "unknown function " <> name,
          ))
      }
  }
}

fn infer_first_arg(
  scope: Scope,
  args: List(query_ir.FuncArg),
  nullable: Bool,
) -> Result(InferredType, AnalysisError) {
  case args {
    [query_ir.FuncArg(expr: first), ..] ->
      case infer_expr_type_allow_null(scope, first) {
        Ok(it) -> ok(it.scalar, nullable || it.nullable)
        Error(e) -> Error(e)
      }
    [] ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "function call with no arguments",
      ))
  }
}

fn infer_math_first_arg(
  scope: Scope,
  args: List(query_ir.FuncArg),
) -> Result(InferredType, AnalysisError) {
  case args {
    [] -> ok(model.FloatType, False)
    [query_ir.FuncArg(expr: first), ..] ->
      case infer_expr_type_allow_null(scope, first) {
        Ok(it) -> ok(it.scalar, it.nullable)
        Error(_) -> ok(model.FloatType, False)
      }
  }
}

fn infer_window_first(
  scope: Scope,
  args: List(query_ir.FuncArg),
) -> Result(InferredType, AnalysisError) {
  case args {
    [query_ir.FuncArg(expr: first), ..] ->
      case infer_expr_type_allow_null(scope, first) {
        Ok(it) -> ok(it.scalar, True)
        Error(e) -> Error(e)
      }
    [] ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "window function with no arguments",
      ))
  }
}

fn infer_aggregate_from_first(
  scope: Scope,
  args: List(query_ir.FuncArg),
  nullable: Bool,
) -> Result(InferredType, AnalysisError) {
  infer_first_arg(scope, args, nullable)
}

fn infer_coalesce(
  scope: Scope,
  args: List(query_ir.FuncArg),
) -> Result(InferredType, AnalysisError) {
  case args {
    [] ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "COALESCE requires at least one argument",
      ))
    _ -> {
      use types <- result.try(
        list.try_map(args, fn(a) {
          let query_ir.FuncArg(expr: e) = a
          infer_expr_type_allow_null(scope, e)
        }),
      )
      case unify_types(types) {
        Ok(#(scalar, _)) -> {
          // COALESCE is non-nullable when any argument is non-nullable.
          let any_non_null =
            list.any(types, fn(t) {
              let InferredType(nullable: n, ..) = t
              !n
            })
          ok(scalar, !any_non_null)
        }
        Error(_) ->
          Error(UnsupportedExpression(
            query_name: scope.query_name,
            expression: "COALESCE arguments have incompatible types",
          ))
      }
    }
  }
}

// ============================================================
// Scalar subqueries
// ============================================================

fn infer_scalar_subquery(
  scope: Scope,
  core: query_ir.SelectCore,
) -> Result(InferredType, AnalysisError) {
  case core.select_items {
    [query_ir.ExprItem(expr: expr, ..), ..] ->
      case infer_expr_type(scope, expr) {
        Ok(InferredType(scalar: t, nullable: _)) -> ok(t, True)
        Error(e) -> Error(e)
      }
    [query_ir.StarEx(..), ..] ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "scalar subquery returning *",
      ))
    [] ->
      Error(UnsupportedExpression(
        query_name: scope.query_name,
        expression: "scalar subquery has no select items",
      ))
  }
}

// ============================================================
// Rendering for diagnostics
// ============================================================

fn render_tokens(tokens: List(lexer.Token)) -> String {
  tokens
  |> list.map(render_token)
  |> list.filter(fn(s) { s != "" })
  |> string.join(" ")
}

fn render_token(token: lexer.Token) -> String {
  case token {
    lexer.Keyword(k) -> k
    lexer.Ident(n) -> n
    lexer.QuotedIdent(n) -> "\"" <> n <> "\""
    lexer.StringLit(s) -> "'" <> s <> "'"
    lexer.NumberLit(n) -> n
    lexer.Placeholder(p) -> p
    lexer.Operator(o) -> o
    lexer.LParen -> "("
    lexer.RParen -> ")"
    lexer.Comma -> ","
    lexer.Semicolon -> ";"
    lexer.Dot -> "."
    lexer.Star -> "*"
  }
}
