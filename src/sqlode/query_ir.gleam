//// Intermediate representation shared between the query parser and the
//// query analyzer. `TokenizedQuery` carries the expanded token list
//// alongside the `ParsedQuery` metadata so analyzer layers can walk
//// tokens without re-tokenizing the SQL string on every pass.

import sqlode/lexer
import sqlode/model

pub type TokenizedQuery {
  TokenizedQuery(base: model.ParsedQuery, tokens: List(lexer.Token))
}
