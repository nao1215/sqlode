import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/column_inferencer
import sqlode/query_analyzer/context
import sqlode/query_analyzer/embed_rewriter
import sqlode/query_analyzer/param_inferencer
import sqlode/query_analyzer/placeholder

pub type AnalysisError =
  context.AnalysisError

pub fn analysis_error_to_string(error: AnalysisError) -> String {
  context.analysis_error_to_string(error)
}

pub fn analyze_queries(
  engine: model.Engine,
  catalog: model.Catalog,
  naming_ctx: naming.NamingContext,
  queries: List(model.ParsedQuery),
) -> Result(List(model.AnalyzedQuery), AnalysisError) {
  let ctx = context.new(naming_ctx)
  list.try_map(queries, analyze_query(ctx, engine, catalog, _))
}

fn analyze_query(
  ctx: context.AnalyzerContext,
  engine: model.Engine,
  catalog: model.Catalog,
  query: model.ParsedQuery,
) -> Result(model.AnalyzedQuery, AnalysisError) {
  // Surface virtual tables the outer query references — CTEs, VALUES
  // in FROM, and derived-table subqueries — so both result-column and
  // parameter inference see them. Nested subqueries rediscover their
  // own VALUES / derived tables inside infer_columns_from_tokens_scoped.
  let tokens = lexer.tokenize(query.sql, engine)
  use cte_tables <- result.try(column_inferencer.extract_cte_tables(
    query.name,
    tokens,
    catalog,
  ))
  let with_ctes = merge_virtual_tables(catalog, cte_tables)
  let values_tables = column_inferencer.extract_values_tables(tokens)
  let with_values = merge_virtual_tables(with_ctes, values_tables)
  use derived_tables <- result.try(column_inferencer.extract_derived_tables(
    query.name,
    tokens,
    with_values,
  ))
  let augmented = merge_virtual_tables(with_values, derived_tables)

  let occurrences = placeholder.extract(ctx, engine, query.sql)
  use params <- result.try(build_params(
    ctx,
    engine,
    query,
    augmented,
    occurrences,
  ))
  use result_columns <- result.try(column_inferencer.infer_result_columns(
    ctx,
    engine,
    query,
    augmented,
  ))

  let rewritten = rewrite_embed_sql(engine, query, tokens, result_columns)
  Ok(model.AnalyzedQuery(base: rewritten, params:, result_columns:))
}

/// Expand any `sqlode.embed(TABLE)` macro calls in the query's SQL into
/// concrete column lists so the emitted runtime SQL is valid. The token
/// list is the already-tokenized form of `query.sql`; reusing it avoids a
/// redundant lex pass when no embed is present.
fn rewrite_embed_sql(
  engine: model.Engine,
  query: model.ParsedQuery,
  tokens: List(lexer.Token),
  result_columns: List(model.ResultItem),
) -> model.ParsedQuery {
  let rewritten_tokens = embed_rewriter.rewrite(tokens, result_columns)
  case rewritten_tokens == tokens {
    True -> query
    False -> {
      let rewritten_sql =
        lexer.tokens_to_string(
          rewritten_tokens,
          lexer.TokenRenderOptions(
            uppercase_keywords: False,
            preserve_quotes: True,
            engine: Some(engine),
          ),
        )
      model.ParsedQuery(..query, sql: rewritten_sql)
    }
  }
}

fn merge_virtual_tables(
  catalog: model.Catalog,
  vtables: List(model.Table),
) -> model.Catalog {
  case vtables {
    [] -> catalog
    _ ->
      model.Catalog(
        tables: list.append(catalog.tables, vtables),
        enums: catalog.enums,
      )
  }
}

fn build_params(
  ctx: context.AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
  occurrences: List(placeholder.PlaceholderOccurrence),
) -> Result(List(model.QueryParam), context.AnalysisError) {
  let inferences =
    list.append(
      param_inferencer.infer_insert_params(ctx, engine, query, catalog),
      param_inferencer.infer_equality_params(ctx, engine, query, catalog),
    )
    |> list.append(param_inferencer.infer_in_params(ctx, engine, query, catalog))

  use cast_dict <- result.try(
    param_inferencer.extract_type_casts(ctx, engine, query.sql)
    |> result.map_error(fn(err) {
      let #(index, cast_type) = err
      context.UnrecognizedCastType(
        query_name: query.name,
        param_index: index,
        cast_type:,
      )
    }),
  )
  let macro_dict = build_macro_dict(query.macros)
  let inference_dict = build_inference_dict(inferences)

  placeholder.unique(occurrences)
  |> list.try_map(fn(occurrence) {
    let macro_info =
      dict.get(macro_dict, occurrence.index) |> option.from_result
    let inferred =
      dict.get(inference_dict, occurrence.index) |> option.from_result

    let cast_type = dict.get(cast_dict, occurrence.index) |> option.from_result
    use inferred_type <- result.try(case inferred {
      Some(column) -> Ok(column.scalar_type)
      None ->
        case cast_type {
          Some(st) -> Ok(st)
          None ->
            Error(context.ParameterTypeNotInferred(
              query_name: query.name,
              param_index: occurrence.index,
            ))
        }
    })

    let #(field_name, scalar_type, nullable, is_list) = case macro_info {
      Some(model.MacroArg(name:, ..)) -> {
        let n = case inferred {
          Some(column) -> column.nullable
          None -> False
        }
        #(naming.to_snake_case(ctx.naming, name), inferred_type, n, False)
      }
      Some(model.MacroNarg(name:, ..)) -> #(
        naming.to_snake_case(ctx.naming, name),
        inferred_type,
        True,
        False,
      )
      Some(model.MacroSlice(name:, ..)) -> #(
        naming.to_snake_case(ctx.naming, name),
        inferred_type,
        False,
        True,
      )
      None ->
        case inferred {
          Some(column) -> #(
            naming.to_snake_case(ctx.naming, column.name),
            column.scalar_type,
            column.nullable,
            False,
          )
          None -> #(occurrence.default_name, inferred_type, False, False)
        }
    }

    Ok(model.QueryParam(
      index: occurrence.index,
      field_name:,
      scalar_type:,
      nullable:,
      is_list:,
    ))
  })
}

fn macro_index(m: model.Macro) -> Int {
  case m {
    model.MacroArg(index: i, ..) -> i
    model.MacroNarg(index: i, ..) -> i
    model.MacroSlice(index: i, ..) -> i
  }
}

fn build_macro_dict(macros: List(model.Macro)) -> dict.Dict(Int, model.Macro) {
  list.fold(macros, dict.new(), fn(d, m) { dict.insert(d, macro_index(m), m) })
}

fn build_inference_dict(
  inferences: List(#(Int, model.Column)),
) -> dict.Dict(Int, model.Column) {
  list.fold(inferences, dict.new(), fn(d, entry) {
    let #(index, column) = entry
    case dict.has_key(d, index) {
      True -> d
      False -> dict.insert(d, index, column)
    }
  })
}
