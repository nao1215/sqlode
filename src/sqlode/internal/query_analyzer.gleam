import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlode/internal/lexer
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer/column_inferencer
import sqlode/internal/query_analyzer/context
import sqlode/internal/query_analyzer/embed_rewriter
import sqlode/internal/query_analyzer/expr_parser
import sqlode/internal/query_analyzer/param_inferencer
import sqlode/internal/query_analyzer/placeholder
import sqlode/internal/query_analyzer/token_utils
import sqlode/internal/query_ir

pub type AnalysisError =
  context.AnalysisError

pub fn analysis_error_to_string(
  error: AnalysisError,
  engine: model.Engine,
) -> String {
  context.analysis_error_to_string(error, engine)
}

pub fn analyze_queries(
  engine: model.Engine,
  catalog: model.Catalog,
  naming_ctx: naming.NamingContext,
  queries: List(query_ir.TokenizedQuery),
) -> Result(List(model.AnalyzedQuery), AnalysisError) {
  let ctx = context.new(naming_ctx)
  list.try_map(queries, analyze_query(ctx, engine, catalog, _))
}

fn analyze_query(
  ctx: context.AnalyzerContext,
  engine: model.Engine,
  catalog: model.Catalog,
  tq: query_ir.TokenizedQuery,
) -> Result(model.AnalyzedQuery, AnalysisError) {
  let query_ir.TokenizedQuery(base: query, tokens: tokens) = tq
  let statement = token_utils.structure_tokens(tokens)
  // Surface virtual tables the outer query references — CTEs, VALUES
  // in FROM, and derived-table subqueries — so both result-column and
  // parameter inference see them. Nested subqueries rediscover their
  // own VALUES / derived tables inside infer_columns_from_tokens_scoped.
  //
  // Issue #406: drive the virtual-table classification from the
  // expression-aware IR (`query_ir.Stmt`) instead of rescanning the
  // raw token stream. The parsed `Stmt` is the single source of
  // truth for WHICH virtual tables exist; when the parser produces
  // `UnstructuredStmt` (an IR gap), we fall back to the token-based
  // extractors. This mirrors the dispatch pattern PRs #412 and #413
  // established for equality / IN / quantified parameter inference.
  let stmt = expr_parser.parse_stmt(tokens, engine)
  use cte_tables <- result.try(case stmt {
    query_ir.UnstructuredStmt(..) ->
      column_inferencer.extract_cte_tables(query.name, tokens, catalog)
    _ ->
      column_inferencer.extract_cte_tables_from_stmt(
        query.name,
        stmt,
        tokens,
        catalog,
      )
  })
  let with_ctes = merge_virtual_tables(catalog, cte_tables)
  let values_tables = case stmt {
    query_ir.UnstructuredStmt(..) ->
      column_inferencer.extract_values_tables(tokens)
    _ -> column_inferencer.extract_values_tables_from_stmt(stmt)
  }
  let with_values = merge_virtual_tables(with_ctes, values_tables)
  use derived_tables <- result.try(case stmt {
    query_ir.UnstructuredStmt(..) ->
      column_inferencer.extract_derived_tables(query.name, tokens, with_values)
    _ ->
      column_inferencer.extract_derived_tables_from_stmt(
        query.name,
        stmt,
        tokens,
        with_values,
      )
  })
  let with_derived = merge_virtual_tables(with_values, derived_tables)
  // Register `FROM table AS alias` / `JOIN table AS alias` aliases so
  // qualified refs like `p.user_id` in a query that writes
  // `FROM posts AS p` resolve to `posts`. This is the single hook
  // that lets the expression-aware IR reason about aliased column
  // references without re-implementing alias resolution everywhere.
  let alias_tables = case stmt {
    query_ir.UnstructuredStmt(..) ->
      column_inferencer.extract_table_aliases(tokens, with_derived)
    _ -> column_inferencer.extract_table_aliases_from_stmt(stmt, with_derived)
  }
  let augmented = merge_virtual_tables(with_derived, alias_tables)

  let occurrences = placeholder.extract(ctx, engine, tokens)
  use params <- result.try(build_params(
    ctx,
    engine,
    query,
    tokens,
    statement,
    augmented,
    occurrences,
  ))
  use result_columns <- result.try(column_inferencer.infer_result_columns(
    ctx,
    engine,
    query,
    tokens,
    statement,
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
  tokens: List(lexer.Token),
  statement: query_ir.SqlStatement,
  catalog: model.Catalog,
  occurrences: List(placeholder.PlaceholderOccurrence),
) -> Result(List(model.QueryParam), context.AnalysisError) {
  // Issue #557: pre-flight check — every table the query references
  // must exist in the schema catalog. Without this, a query that
  // names a table not in `schema.sql` falls through every inferencer
  // (column lookup returns `None`, the param is silently skipped) and
  // surfaces only at the final pass as `ParameterTypeNotInferred` with
  // an unhelpful CAST hint. Catching the missing table up front lets
  // us point the user at the real cause: the table is not in the
  // schema.
  use _ <- result.try(check_referenced_tables_exist(
    catalog,
    query.name,
    tokens,
    statement,
  ))
  use equality <- result.try(param_inferencer.infer_equality_params(
    ctx,
    engine,
    query.name,
    tokens,
    catalog,
  ))
  use in_params <- result.try(param_inferencer.infer_in_params(
    ctx,
    engine,
    query.name,
    tokens,
    catalog,
  ))
  let inferences =
    param_inferencer.infer_insert_params_from_ir(engine, statement, catalog)
    |> list.append(equality)
    |> list.append(in_params)

  use cast_dict <- result.try(
    param_inferencer.extract_type_casts(ctx, engine, tokens)
    |> result.map_error(fn(err) {
      let #(index, cast_type) = err
      context.UnrecognizedCastType(
        query_name: query.name,
        param_index: index,
        cast_type:,
      )
    }),
  )
  // Issue #491: LIMIT/OFFSET placeholders are integer by SQL spec, even
  // without an explicit cast. Merge their inferred types into the cast
  // dict so a `?` in `LIMIT ?` / `OFFSET ?` resolves to `IntType`. Any
  // user-written `CAST(? AS <type>)` still wins because `extract_type_casts`
  // is layered on top.
  let int_context_dict =
    param_inferencer.extract_int_context_params(tokens, engine)
  let cast_dict = dict.merge(int_context_dict, cast_dict)
  let macro_dict = build_macro_dict(query.macros)
  use inference_dict <- result.try(build_inference_dict(query.name, inferences))

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
        let nullable = case inferred {
          Some(column) -> column.nullable
          None -> False
        }
        #(
          naming.to_snake_case(ctx.naming, name),
          inferred_type,
          nullable,
          False,
        )
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

/// Issue #557: pre-flight check that every table the query references
/// is in the schema catalog. Run before parameter inference so the
/// user sees a `TableNotFound` diagnostic naming the missing table,
/// not a downstream `ParameterTypeNotInferred` that points at a CAST
/// fix that can't actually fix the underlying problem.
///
/// The check uses the structural IR (`SqlStatement`):
///
/// - `SelectStatement` walks the FROM/JOIN tokens via
///   `extract_table_names` (the same shape `infer_equality_params`
///   uses to set up the column-lookup scope).
/// - `InsertStatement` / `UpdateStatement` / `DeleteStatement` use
///   the IR-provided `table_name` only; the token extractor would
///   pick up `display_name` from a MySQL `ON DUPLICATE KEY UPDATE
///   display_name = …` clause as if `UPDATE` had introduced a table,
///   surfacing as a false `TableNotFound` against perfectly
///   well-formed upserts.
/// - `UnstructuredStatement` skips the check entirely. The structurer
///   gave up on this token stream, so any table-name extraction
///   would be best-effort and risk false positives. The downstream
///   `ParameterTypeNotInferred` path still applies for those cases;
///   covering them too is a follow-up that needs a richer IR.
///
/// CTE-defined virtual tables are already merged into the catalog by
/// `merge_virtual_tables` before `build_params` runs, so they are
/// part of `catalog.tables` and pass this check.
fn check_referenced_tables_exist(
  catalog: model.Catalog,
  query_name: String,
  tokens: List(lexer.Token),
  statement: query_ir.SqlStatement,
) -> Result(Nil, context.AnalysisError) {
  let referenced = case statement {
    query_ir.InsertStatement(table_name:, ..) -> [table_name]
    query_ir.UpdateStatement(table_name:, ..) -> [table_name]
    query_ir.DeleteStatement(table_name:, ..) -> [table_name]
    query_ir.SelectStatement(..) -> {
      let main_tokens = token_utils.strip_leading_with(tokens)
      token_utils.extract_table_names(main_tokens)
    }
    query_ir.UnstructuredStatement(..) -> []
  }
  case list.find(referenced, fn(name) { !table_in_catalog(catalog, name) }) {
    Ok(missing) ->
      Error(context.TableNotFound(query_name: query_name, table_name: missing))
    Error(_) -> Ok(Nil)
  }
}

fn table_in_catalog(catalog: model.Catalog, name: String) -> Bool {
  let normalized = naming.normalize_identifier(name)
  list.any(catalog.tables, fn(t) { t.name == normalized })
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
  query_name: String,
  inferences: List(#(Int, model.Column)),
) -> Result(dict.Dict(Int, model.Column), context.AnalysisError) {
  list.try_fold(inferences, dict.new(), fn(d, entry) {
    let #(index, model.Column(scalar_type: new_type, ..)) = entry
    case dict.get(d, index) {
      Ok(model.Column(scalar_type: existing_type, ..)) ->
        case existing_type == new_type {
          True -> Ok(d)
          False ->
            Error(context.ParameterTypeConflict(
              query_name:,
              param_index: index,
              type_a: existing_type,
              type_b: new_type,
            ))
        }
      Error(_) -> {
        let #(_, column) = entry
        Ok(dict.insert(d, index, column))
      }
    }
  })
}
