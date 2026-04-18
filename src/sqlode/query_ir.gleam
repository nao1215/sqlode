//// Intermediate representation shared between the query parser and the
//// query analyzer. `TokenizedQuery` carries the expanded token list
//// alongside the `ParsedQuery` metadata so analyzer layers can walk
//// tokens without re-tokenizing the SQL string on every pass.
////
//// `StructuredQuery` adds a thin structural layer that identifies the
//// statement kind and its major clauses (tables, SELECT items, WHERE
//// predicates, etc.) so inference passes can consume pre-parsed
//// structure instead of re-scanning the raw token list.

import gleam/option.{type Option}
import sqlode/lexer
import sqlode/model

pub type TokenizedQuery {
  TokenizedQuery(base: model.ParsedQuery, tokens: List(lexer.Token))
}

// ============================================================
// Structured IR — statement-level decomposition
// ============================================================

/// Top-level statement structure extracted from the token list.
pub type SqlStatement {
  SelectStatement(
    select_items: List(SelectItem),
    from: List(FromItem),
    joins: List(JoinClause),
    where_tokens: Option(List(lexer.Token)),
    group_by_tokens: Option(List(lexer.Token)),
    having_tokens: Option(List(lexer.Token)),
    order_by_tokens: Option(List(lexer.Token)),
    limit_tokens: Option(List(lexer.Token)),
  )
  InsertStatement(
    table_name: String,
    columns: List(String),
    value_groups: List(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  UpdateStatement(
    table_name: String,
    set_tokens: List(lexer.Token),
    where_tokens: Option(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  DeleteStatement(
    table_name: String,
    where_tokens: Option(List(lexer.Token)),
    returning_tokens: Option(List(lexer.Token)),
  )
  /// Fallback for statements that don't match the above patterns.
  UnstructuredStatement(tokens: List(lexer.Token))
}

/// A single item in a SELECT list.
pub type SelectItem {
  /// `*` or `table.*`
  StarItem(table_prefix: Option(String))
  /// An expression, possibly aliased
  ExpressionItem(tokens: List(lexer.Token), alias: Option(String))
}

/// A table or subquery in the FROM clause.
pub type FromItem {
  TableRef(name: String, alias: Option(String))
  SubqueryRef(tokens: List(lexer.Token), alias: Option(String))
}

/// A JOIN clause.
pub type JoinClause {
  JoinClause(
    table_name: String,
    alias: Option(String),
    on_tokens: Option(List(lexer.Token)),
  )
}

/// `StructuredQuery` wraps `TokenizedQuery` with the structured IR.
/// The raw token list is preserved for backward compatibility with
/// code that hasn't migrated to the structured representation yet.
pub type StructuredQuery {
  StructuredQuery(
    base: model.ParsedQuery,
    tokens: List(lexer.Token),
    statement: SqlStatement,
  )
}
