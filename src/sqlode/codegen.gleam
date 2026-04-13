import sqlode/codegen/adapter
import sqlode/codegen/models
import sqlode/codegen/params
import sqlode/codegen/queries
import sqlode/model
import sqlode/naming

pub fn render_queries_module(
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
) -> String {
  queries.render(block, analyzed)
}

pub fn render_params_module(
  naming_ctx: naming.NamingContext,
  analyzed: List(model.AnalyzedQuery),
) -> String {
  params.render(naming_ctx, analyzed)
}

pub fn render_models_module(
  naming_ctx: naming.NamingContext,
  analyzed: List(model.AnalyzedQuery),
) -> String {
  models.render(naming_ctx, analyzed)
}

pub fn render_adapter_module(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
) -> String {
  adapter.render(naming_ctx, block, analyzed)
}
