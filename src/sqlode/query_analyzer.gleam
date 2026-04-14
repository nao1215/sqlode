import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer/column_inferencer
import sqlode/query_analyzer/context
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
  let occurrences = placeholder.extract(ctx, engine, query.sql)
  let params = build_params(ctx, engine, query, catalog, occurrences)
  use result_columns <- result.try(column_inferencer.infer_result_columns(
    ctx,
    query,
    catalog,
  ))

  Ok(model.AnalyzedQuery(base: query, params:, result_columns:))
}

fn build_params(
  ctx: context.AnalyzerContext,
  engine: model.Engine,
  query: model.ParsedQuery,
  catalog: model.Catalog,
  occurrences: List(placeholder.PlaceholderOccurrence),
) -> List(model.QueryParam) {
  let inferences =
    list.append(
      param_inferencer.infer_insert_params(ctx, engine, query, catalog),
      param_inferencer.infer_equality_params(ctx, engine, query, catalog),
    )
    |> list.append(param_inferencer.infer_in_params(ctx, engine, query, catalog))

  let cast_dict = param_inferencer.extract_type_casts(ctx, engine, query.sql)
  let macro_dict = build_macro_dict(query.macros)
  let inference_dict = build_inference_dict(inferences)

  placeholder.unique(occurrences)
  |> list.map(fn(occurrence) {
    let macro_info =
      dict.get(macro_dict, occurrence.index) |> option.from_result
    let inferred =
      dict.get(inference_dict, occurrence.index) |> option.from_result

    let cast_type = dict.get(cast_dict, occurrence.index) |> option.from_result
    let inferred_type = case inferred {
      Some(column) -> column.scalar_type
      None ->
        case cast_type {
          Some(st) -> st
          None -> model.StringType
        }
    }

    let #(field_name, scalar_type, nullable, is_list) = case macro_info {
      Some(model.SqlcArg(name:, ..)) -> {
        let n = case inferred {
          Some(column) -> column.nullable
          None -> False
        }
        #(naming.to_snake_case(ctx.naming, name), inferred_type, n, False)
      }
      Some(model.SqlcNarg(name:, ..)) -> #(
        naming.to_snake_case(ctx.naming, name),
        inferred_type,
        True,
        False,
      )
      Some(model.SqlcSlice(name:, ..)) -> #(
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
          None -> #(
            occurrence.default_name,
            case cast_type {
              Some(st) -> st
              None -> model.StringType
            },
            False,
            False,
          )
        }
    }

    model.QueryParam(
      index: occurrence.index,
      field_name:,
      scalar_type:,
      nullable:,
      is_list:,
    )
  })
}

fn macro_index(m: model.SqlcMacro) -> Int {
  case m {
    model.SqlcArg(index: i, ..) -> i
    model.SqlcNarg(index: i, ..) -> i
    model.SqlcSlice(index: i, ..) -> i
  }
}

fn build_macro_dict(
  macros: List(model.SqlcMacro),
) -> dict.Dict(Int, model.SqlcMacro) {
  list.fold(macros, dict.new(), fn(d, m) { dict.insert(d, macro_index(m), m) })
}

fn build_inference_dict(
  inferences: List(#(Int, model.Column)),
) -> dict.Dict(Int, model.Column) {
  list.fold(inferences, dict.new(), fn(d, entry) {
    let #(index, column) = entry
    dict.insert(d, index, column)
  })
}
