import gleam/dict.{type Dict}
import sqlode/codegen/adapter
import sqlode/codegen/models
import sqlode/codegen/params
import sqlode/codegen/queries
import sqlode/model
import sqlode/naming

pub fn render_queries_module(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
) -> String {
  queries.render(naming_ctx, block, analyzed)
}

pub fn render_params_module(
  naming_ctx: naming.NamingContext,
  analyzed: List(model.AnalyzedQuery),
  type_mapping: model.TypeMapping,
  module_path: String,
) -> String {
  params.render(naming_ctx, analyzed, type_mapping, module_path)
}

pub fn render_models_module(
  naming_ctx: naming.NamingContext,
  catalog: model.Catalog,
  analyzed: List(model.AnalyzedQuery),
  table_matches: Dict(String, String),
  type_mapping: model.TypeMapping,
  emit_exact_table_names: Bool,
) -> String {
  models.render(
    naming_ctx,
    catalog,
    analyzed,
    table_matches,
    type_mapping,
    emit_exact_table_names,
  )
}

pub fn render_adapter_module(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
  table_matches: Dict(String, String),
) -> String {
  adapter.render(naming_ctx, block, analyzed, table_matches)
}
