import codegen_test
import config_test
import gleeunit
import query_analyzer_test
import query_parser_test
import schema_parser_test

pub fn main() {
  gleeunit.main()
}

pub fn load_sqlc_style_config_test() {
  config_test.load_sqlc_style_config_test()
}

pub fn reject_unsupported_config_version_test() {
  config_test.reject_unsupported_config_version_test()
}

pub fn parse_queries_from_sqlc_annotations_test() {
  query_parser_test.parse_queries_from_sqlc_annotations_test()
}

pub fn reject_query_without_sql_body_test() {
  query_parser_test.reject_query_without_sql_body_test()
}

pub fn count_mysql_placeholders_test() {
  query_parser_test.count_mysql_placeholders_test()
}

pub fn count_sqlite_named_placeholders_test() {
  query_parser_test.count_sqlite_named_placeholders_test()
}

pub fn expand_sqlc_arg_macro_test() {
  query_parser_test.expand_sqlc_arg_macro_test()
}

pub fn expand_sqlc_narg_macro_test() {
  query_parser_test.expand_sqlc_narg_macro_test()
}

pub fn expand_sqlc_arg_mysql_test() {
  query_parser_test.expand_sqlc_arg_mysql_test()
}

pub fn parse_create_table_columns_test() {
  schema_parser_test.parse_create_table_columns_test()
}

pub fn parse_extended_types_test() {
  schema_parser_test.parse_extended_types_test()
}

pub fn infer_param_type_from_where_clause_test() {
  query_analyzer_test.infer_param_type_from_where_clause_test()
}

pub fn infer_insert_param_types_from_column_order_test() {
  query_analyzer_test.infer_insert_param_types_from_column_order_test()
}

pub fn infer_result_columns_for_select_test() {
  query_analyzer_test.infer_result_columns_for_select_test()
}

pub fn infer_no_result_columns_for_exec_test() {
  query_analyzer_test.infer_no_result_columns_for_exec_test()
}

pub fn infer_result_columns_with_star_test() {
  query_analyzer_test.infer_result_columns_with_star_test()
}

pub fn infer_result_columns_with_table_prefix_test() {
  query_analyzer_test.infer_result_columns_with_table_prefix_test()
}

pub fn sqlc_arg_sets_param_name_test() {
  query_analyzer_test.sqlc_arg_sets_param_name_test()
}

pub fn sqlc_narg_sets_nullable_test() {
  query_analyzer_test.sqlc_narg_sets_nullable_test()
}

pub fn sqlc_slice_sets_is_list_test() {
  query_analyzer_test.sqlc_slice_sets_is_list_test()
}

pub fn parse_enum_column_type_test() {
  query_analyzer_test.parse_enum_column_type_test()
}

pub fn render_queries_module_test() {
  codegen_test.render_queries_module_test()
}

pub fn render_params_module_test() {
  codegen_test.render_params_module_test()
}

pub fn render_models_module_test() {
  codegen_test.render_models_module_test()
}

pub fn render_models_module_with_nullable_test() {
  codegen_test.render_models_module_with_nullable_test()
}

pub fn render_models_module_no_exec_rows_test() {
  codegen_test.render_models_module_no_exec_rows_test()
}

pub fn render_pog_adapter_test() {
  codegen_test.render_pog_adapter_test()
}

pub fn render_sqlight_adapter_test() {
  codegen_test.render_sqlight_adapter_test()
}
