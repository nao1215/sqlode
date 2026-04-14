import codegen_test
import config_test
import generate_test
import gleeunit
import query_analyzer_test
import query_parser_test
import schema_parser_test
import writer_test

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

pub fn type_cast_infers_param_type_test() {
  query_analyzer_test.type_cast_infers_param_type_test()
}

pub fn join_result_columns_test() {
  query_analyzer_test.join_result_columns_test()
}

pub fn sqlc_embed_expands_table_columns_test() {
  query_analyzer_test.sqlc_embed_expands_table_columns_test()
}

pub fn returning_clause_result_columns_test() {
  query_analyzer_test.returning_clause_result_columns_test()
}

pub fn cte_select_from_real_table_test() {
  query_analyzer_test.cte_select_from_real_table_test()
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

pub fn render_params_module_slice_test() {
  codegen_test.render_params_module_slice_test()
}

pub fn render_pog_adapter_slice_test() {
  codegen_test.render_pog_adapter_slice_test()
}

pub fn render_sqlight_adapter_slice_test() {
  codegen_test.render_sqlight_adapter_slice_test()
}

pub fn expand_slice_placeholders_single_test() {
  codegen_test.expand_slice_placeholders_single_test()
}

pub fn expand_slice_placeholders_with_renumbering_test() {
  codegen_test.expand_slice_placeholders_with_renumbering_test()
}

pub fn expand_slice_placeholders_sqlite_test() {
  codegen_test.expand_slice_placeholders_sqlite_test()
}

pub fn expand_slice_placeholders_no_slices_test() {
  codegen_test.expand_slice_placeholders_no_slices_test()
}

pub fn type_override_changes_scalar_type_test() {
  generate_test.type_override_changes_scalar_type_test()
}

pub fn type_override_case_insensitive_db_type_test() {
  generate_test.type_override_case_insensitive_db_type_test()
}

pub fn type_override_preserves_unmatched_columns_test() {
  generate_test.type_override_preserves_unmatched_columns_test()
}

pub fn type_override_multiple_overrides_test() {
  generate_test.type_override_multiple_overrides_test()
}

pub fn no_overrides_leaves_types_unchanged_test() {
  generate_test.no_overrides_leaves_types_unchanged_test()
}

pub fn column_rename_changes_field_name_test() {
  generate_test.column_rename_changes_field_name_test()
}

pub fn column_rename_case_insensitive_match_test() {
  generate_test.column_rename_case_insensitive_match_test()
}

pub fn column_rename_only_applies_to_matching_table_test() {
  generate_test.column_rename_only_applies_to_matching_table_test()
}

pub fn combined_type_override_and_column_rename_test() {
  generate_test.combined_type_override_and_column_rename_test()
}

pub fn column_override_changes_specific_column_test() {
  generate_test.column_override_changes_specific_column_test()
}

pub fn column_override_takes_precedence_over_db_type_test() {
  generate_test.column_override_takes_precedence_over_db_type_test()
}

pub fn column_override_does_not_affect_other_tables_test() {
  generate_test.column_override_does_not_affect_other_tables_test()
}

pub fn nullable_override_applies_only_to_nullable_columns_test() {
  generate_test.nullable_override_applies_only_to_nullable_columns_test()
}

pub fn non_nullable_override_applies_only_to_non_nullable_columns_test() {
  generate_test.non_nullable_override_applies_only_to_non_nullable_columns_test()
}

pub fn nullable_none_override_applies_to_all_test() {
  generate_test.nullable_none_override_applies_to_all_test()
}

pub fn all_commands_generate_queries_test() {
  generate_test.all_commands_generate_queries_test()
}

pub fn all_commands_generate_params_test() {
  generate_test.all_commands_generate_params_test()
}

pub fn all_commands_generate_models_test() {
  generate_test.all_commands_generate_models_test()
}

pub fn all_commands_sqlight_adapter_test() {
  generate_test.all_commands_sqlight_adapter_test()
}

// --- Writer tests ---

pub fn write_all_creates_files_test() {
  writer_test.write_all_creates_files_test()
}

pub fn write_all_creates_directory_test() {
  writer_test.write_all_creates_directory_test()
}

pub fn write_all_multiple_files_test() {
  writer_test.write_all_multiple_files_test()
}

pub fn write_all_empty_list_test() {
  writer_test.write_all_empty_list_test()
}

pub fn write_all_returns_paths_in_order_test() {
  writer_test.write_all_returns_paths_in_order_test()
}

pub fn error_to_string_directory_error_test() {
  writer_test.error_to_string_directory_error_test()
}

pub fn error_to_string_file_error_test() {
  writer_test.error_to_string_file_error_test()
}

// --- Generate error path tests ---

pub fn run_with_missing_config_test() {
  generate_test.run_with_missing_config_test()
}

pub fn run_with_missing_schema_file_test() {
  generate_test.run_with_missing_schema_file_test()
}

pub fn run_with_missing_query_file_test() {
  generate_test.run_with_missing_query_file_test()
}

pub fn run_with_no_queries_in_file_test() {
  generate_test.run_with_no_queries_in_file_test()
}

// --- UNION/INTERSECT/EXCEPT tests ---

pub fn union_all_infers_columns_from_first_select_test() {
  generate_test.union_all_infers_columns_from_first_select_test()
}

pub fn union_infers_columns_test() {
  generate_test.union_infers_columns_test()
}

pub fn intersect_infers_columns_test() {
  generate_test.intersect_infers_columns_test()
}

pub fn except_infers_columns_test() {
  generate_test.except_infers_columns_test()
}

// --- VIEW tests ---

pub fn view_select_columns_inferred_test() {
  generate_test.view_select_columns_inferred_test()
}

pub fn view_select_star_inferred_test() {
  generate_test.view_select_star_inferred_test()
}

pub fn run_resolves_paths_relative_to_config_dir_test() {
  generate_test.run_resolves_paths_relative_to_config_dir_test()
}

pub fn out_to_module_path_strips_src_prefix_test() {
  codegen_test.out_to_module_path_strips_src_prefix_test()
}

pub fn accept_directory_for_schema_and_queries_test() {
  generate_test.accept_directory_for_schema_and_queries_test()
}

pub fn mixed_file_and_directory_inputs_test() {
  generate_test.mixed_file_and_directory_inputs_test()
}

pub fn ignore_placeholder_in_single_quoted_string_test() {
  query_parser_test.ignore_placeholder_in_single_quoted_string_test()
}

pub fn ignore_placeholder_in_line_comment_test() {
  query_parser_test.ignore_placeholder_in_line_comment_test()
}

pub fn ignore_placeholder_in_block_comment_test() {
  query_parser_test.ignore_placeholder_in_block_comment_test()
}

pub fn ignore_at_name_in_string_literal_test() {
  query_parser_test.ignore_at_name_in_string_literal_test()
}

pub fn ignore_question_mark_in_string_mysql_test() {
  query_parser_test.ignore_question_mark_in_string_mysql_test()
}
