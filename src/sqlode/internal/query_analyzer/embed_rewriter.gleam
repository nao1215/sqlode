//// Expand `sqlode.embed(TABLE)` macro calls into concrete qualified column
//// lists inside an already-tokenized query. The rewriter is meant to run
//// after `column_inferencer.infer_result_columns` so that the
//// `EmbeddedResult` entries it receives already have the table's column
//// list resolved against the catalog.

import gleam/list
import gleam/string
import sqlode/internal/lexer
import sqlode/internal/model

/// Rewrite token list, replacing every `sqlode.embed(TABLE)` occurrence with
/// a comma-separated list of qualified columns derived from the matching
/// `EmbeddedResult` in `result_columns`.
///
/// If `result_columns` contains no `EmbeddedResult`, tokens are returned
/// unchanged — callers can use this to short-circuit re-rendering when
/// there is nothing to do.
pub fn rewrite(
  tokens: List(lexer.Token),
  result_columns: List(model.ResultItem),
) -> List(lexer.Token) {
  let embeds = collect_embeds(result_columns)
  case embeds {
    [] -> tokens
    _ -> do_rewrite(tokens, embeds, [])
  }
}

fn collect_embeds(
  result_columns: List(model.ResultItem),
) -> List(model.EmbeddedColumn) {
  list.filter_map(result_columns, fn(item) {
    case item {
      model.EmbeddedResult(embed) -> Ok(embed)
      model.ScalarResult(_) -> Error(Nil)
    }
  })
}

fn do_rewrite(
  tokens: List(lexer.Token),
  embeds: List(model.EmbeddedColumn),
  acc: List(lexer.Token),
) -> List(lexer.Token) {
  case try_match_embed(tokens) {
    Ok(#(table_token, rest)) ->
      case find_embed(embeds, table_token) {
        Ok(embed) -> {
          let replacement = build_column_tokens(embed)
          do_rewrite(rest, embeds, prepend_reversed(replacement, acc))
        }
        Error(Nil) -> advance_one(tokens, embeds, acc)
      }
    Error(Nil) -> advance_one(tokens, embeds, acc)
  }
}

fn advance_one(
  tokens: List(lexer.Token),
  embeds: List(model.EmbeddedColumn),
  acc: List(lexer.Token),
) -> List(lexer.Token) {
  case tokens {
    [] -> list.reverse(acc)
    [t, ..rest] -> do_rewrite(rest, embeds, [t, ..acc])
  }
}

fn try_match_embed(
  tokens: List(lexer.Token),
) -> Result(#(String, List(lexer.Token)), Nil) {
  case tokens {
    [
      lexer.Ident(sqlode_tok),
      lexer.Dot,
      lexer.Ident(embed_tok),
      lexer.LParen,
      lexer.Ident(table_tok),
      lexer.RParen,
      ..rest
    ] ->
      case
        string.lowercase(sqlode_tok) == "sqlode"
        && string.lowercase(embed_tok) == "embed"
      {
        True -> Ok(#(table_tok, rest))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn find_embed(
  embeds: List(model.EmbeddedColumn),
  table_token: String,
) -> Result(model.EmbeddedColumn, Nil) {
  let key = string.lowercase(table_token)
  list.find(embeds, fn(e) { e.table_name == key })
}

fn build_column_tokens(embed: model.EmbeddedColumn) -> List(lexer.Token) {
  embed.columns
  |> list.index_map(fn(col, idx) {
    let prefix = case idx {
      0 -> []
      _ -> [lexer.Comma]
    }
    list.append(prefix, [
      lexer.Ident(embed.table_name),
      lexer.Dot,
      lexer.Ident(col.name),
    ])
  })
  |> list.flatten
}

fn prepend_reversed(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [x, ..rest] -> prepend_reversed(rest, [x, ..acc])
  }
}
