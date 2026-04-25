import cli_test
import codegen_test
import config_test
import entry_test
import generate_test
import gleeunit
import lexer_test
import model_test
import naming_test
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

pub fn view_with_cast_expression_test() {
  schema_parser_test.view_with_cast_expression_test()
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

pub fn left_join_makes_right_table_nullable_test() {
  query_analyzer_test.left_join_makes_right_table_nullable_test()
}

pub fn right_join_makes_left_table_nullable_test() {
  query_analyzer_test.right_join_makes_left_table_nullable_test()
}

pub fn full_join_makes_both_tables_nullable_test() {
  query_analyzer_test.full_join_makes_both_tables_nullable_test()
}

pub fn sqlc_embed_expands_table_columns_test() {
  query_analyzer_test.sqlc_embed_expands_table_columns_test()
}

pub fn sqlc_embed_rewrites_sql_to_column_list_test() {
  query_analyzer_test.sqlc_embed_rewrites_sql_to_column_list_test()
}

pub fn sqlc_embed_rewrite_ignores_case_and_whitespace_test() {
  query_analyzer_test.sqlc_embed_rewrite_ignores_case_and_whitespace_test()
}

pub fn sqlc_embed_rewrite_preserves_queries_without_embed_test() {
  query_analyzer_test.sqlc_embed_rewrite_preserves_queries_without_embed_test()
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

pub fn execresult_rejected_on_native_runtime_test() {
  generate_test.execresult_rejected_on_native_runtime_test()
}

pub fn execresult_allowed_on_raw_runtime_test() {
  generate_test.execresult_allowed_on_raw_runtime_test()
}

pub fn emit_sql_as_comment_includes_sql_in_output_test() {
  generate_test.emit_sql_as_comment_includes_sql_in_output_test()
}

pub fn omits_sql_comment_by_default_test() {
  generate_test.omits_sql_comment_by_default_test()
}

pub fn emit_exact_table_names_skips_singularization_test() {
  generate_test.emit_exact_table_names_skips_singularization_test()
}

pub fn singularizes_table_names_by_default_test() {
  generate_test.singularizes_table_names_by_default_test()
}

pub fn render_enum_from_string_returns_result_test() {
  codegen_test.render_enum_from_string_returns_result_test()
}

pub fn render_enum_decoder_uses_decode_then_test() {
  codegen_test.render_enum_decoder_uses_decode_then_test()
}

pub fn render_pog_adapter_enum_slice_converts_to_string_test() {
  codegen_test.render_pog_adapter_enum_slice_converts_to_string_test()
}

pub fn render_sqlight_adapter_enum_slice_converts_to_string_test() {
  codegen_test.render_sqlight_adapter_enum_slice_converts_to_string_test()
}

// escape_string tests

pub fn escape_string_backslash_test() {
  codegen_test.escape_string_backslash_test()
}

pub fn escape_string_double_quote_test() {
  codegen_test.escape_string_double_quote_test()
}

pub fn escape_string_newline_and_tab_test() {
  codegen_test.escape_string_newline_and_tab_test()
}

pub fn escape_string_carriage_return_test() {
  codegen_test.escape_string_carriage_return_test()
}

pub fn escape_string_no_special_chars_test() {
  codegen_test.escape_string_no_special_chars_test()
}

// model tests

pub fn parse_type_mapping_string_test() {
  model_test.parse_type_mapping_string_test()
}

pub fn parse_type_mapping_rich_test() {
  model_test.parse_type_mapping_rich_test()
}

pub fn parse_type_mapping_invalid_test() {
  model_test.parse_type_mapping_invalid_test()
}

pub fn is_rich_type_datetime_test() {
  model_test.is_rich_type_datetime_test()
}

pub fn is_rich_type_non_rich_test() {
  model_test.is_rich_type_non_rich_test()
}

pub fn scalar_type_to_decoder_sqlite_bool_test() {
  model_test.scalar_type_to_decoder_sqlite_bool_test()
}

pub fn scalar_type_to_decoder_postgresql_bool_test() {
  model_test.scalar_type_to_decoder_postgresql_bool_test()
}

pub fn scalar_type_to_value_function_bytes_postgresql_test() {
  model_test.scalar_type_to_value_function_bytes_postgresql_test()
}

pub fn scalar_type_to_value_function_bytes_sqlite_test() {
  model_test.scalar_type_to_value_function_bytes_sqlite_test()
}

pub fn enum_type_name_test() {
  model_test.enum_type_name_test()
}

pub fn enum_value_name_test() {
  model_test.enum_value_name_test()
}

pub fn enum_to_string_fn_test() {
  model_test.enum_to_string_fn_test()
}

pub fn enum_from_string_fn_test() {
  model_test.enum_from_string_fn_test()
}

// schema_parser view tests

pub fn view_basic_select_test() {
  schema_parser_test.view_basic_select_test()
}

pub fn view_with_alias_test() {
  schema_parser_test.view_with_alias_test()
}

pub fn view_star_test() {
  schema_parser_test.view_star_test()
}

pub fn view_or_replace_test() {
  schema_parser_test.view_or_replace_test()
}

pub fn view_nonexistent_table_test() {
  schema_parser_test.view_nonexistent_table_test()
}

pub fn view_with_count_expression_test() {
  schema_parser_test.view_with_count_expression_test()
}

pub fn view_with_sum_expression_test() {
  schema_parser_test.view_with_sum_expression_test()
}

pub fn view_with_avg_expression_test() {
  schema_parser_test.view_with_avg_expression_test()
}

pub fn view_with_coalesce_expression_test() {
  schema_parser_test.view_with_coalesce_expression_test()
}

pub fn view_with_literal_expression_test() {
  schema_parser_test.view_with_literal_expression_test()
}

// query_analyzer error tests

pub fn table_not_found_error_test() {
  query_analyzer_test.table_not_found_error_test()
}

pub fn analysis_error_to_string_table_not_found_test() {
  query_analyzer_test.analysis_error_to_string_table_not_found_test()
}

pub fn analysis_error_to_string_column_not_found_test() {
  query_analyzer_test.analysis_error_to_string_column_not_found_test()
}

pub fn parameter_type_not_inferred_error_test() {
  query_analyzer_test.parameter_type_not_inferred_error_test()
}

pub fn unrecognized_cast_type_error_test() {
  query_analyzer_test.unrecognized_cast_type_error_test()
}

pub fn analysis_error_to_string_parameter_not_inferred_test() {
  query_analyzer_test.analysis_error_to_string_parameter_not_inferred_test()
}

pub fn analysis_error_to_string_unrecognized_cast_test() {
  query_analyzer_test.analysis_error_to_string_unrecognized_cast_test()
}

pub fn unrecognized_sql_type_returns_error_test() {
  schema_parser_test.unrecognized_sql_type_returns_error_test()
}

pub fn singularize_regular_plural_test() {
  naming_test.singularize_regular_plural_test()
}

pub fn singularize_compound_table_names_test() {
  naming_test.singularize_compound_table_names_test()
}

pub fn pascal_case_empty_string_test() {
  naming_test.pascal_case_empty_string_test()
}

pub fn snake_case_empty_string_test() {
  naming_test.snake_case_empty_string_test()
}

pub fn pascal_case_only_underscores_test() {
  naming_test.pascal_case_only_underscores_test()
}

pub fn snake_case_only_underscores_test() {
  naming_test.snake_case_only_underscores_test()
}

pub fn pascal_case_only_numbers_test() {
  naming_test.pascal_case_only_numbers_test()
}

pub fn snake_case_only_numbers_test() {
  naming_test.snake_case_only_numbers_test()
}

pub fn pascal_case_single_lower_char_test() {
  naming_test.pascal_case_single_lower_char_test()
}

pub fn pascal_case_single_upper_char_test() {
  naming_test.pascal_case_single_upper_char_test()
}

pub fn snake_case_single_upper_char_test() {
  naming_test.snake_case_single_upper_char_test()
}

pub fn normalize_identifier_empty_test() {
  naming_test.normalize_identifier_empty_test()
}

pub fn normalize_identifier_whitespace_only_test() {
  naming_test.normalize_identifier_whitespace_only_test()
}

pub fn singularize_empty_test() {
  naming_test.singularize_empty_test()
}

pub fn singularize_single_char_test() {
  naming_test.singularize_single_char_test()
}

pub fn normalize_identifier_unicode_test() {
  naming_test.normalize_identifier_unicode_test()
}

pub fn singularize_unicode_preserves_input_test() {
  naming_test.singularize_unicode_preserves_input_test()
}

pub fn sqlite_repeated_colon_placeholder_dedup_test() {
  query_parser_test.sqlite_repeated_colon_placeholder_dedup_test()
}

pub fn sqlite_repeated_dollar_placeholder_dedup_test() {
  query_parser_test.sqlite_repeated_dollar_placeholder_dedup_test()
}

pub fn sqlite_repeated_at_placeholder_dedup_test() {
  query_parser_test.sqlite_repeated_at_placeholder_dedup_test()
}

pub fn sqlite_distinct_named_placeholders_not_deduped_test() {
  query_parser_test.sqlite_distinct_named_placeholders_not_deduped_test()
}

pub fn sqlite_colon_and_at_are_different_params_test() {
  query_parser_test.sqlite_colon_and_at_are_different_params_test()
}

pub fn sqlite_bare_question_marks_not_deduped_test() {
  query_parser_test.sqlite_bare_question_marks_not_deduped_test()
}

pub fn sqlite_repeated_numbered_placeholder_dedup_test() {
  query_parser_test.sqlite_repeated_numbered_placeholder_dedup_test()
}

pub fn postgresql_plain_dollar_quoted_string_masks_placeholder_test() {
  query_parser_test.postgresql_plain_dollar_quoted_string_masks_placeholder_test()
}

pub fn postgresql_tagged_dollar_quoted_string_masks_placeholder_test() {
  query_parser_test.postgresql_tagged_dollar_quoted_string_masks_placeholder_test()
}

pub fn postgresql_dollar_quoted_does_not_affect_real_params_test() {
  query_parser_test.postgresql_dollar_quoted_does_not_affect_real_params_test()
}

pub fn sqlite_dollar_not_treated_as_dollar_quoted_test() {
  query_parser_test.sqlite_dollar_not_treated_as_dollar_quoted_test()
}

pub fn tagged_dollar_quoted_string_postgresql_test() {
  lexer_test.tagged_dollar_quoted_string_postgresql_test()
}

pub fn nested_dollar_quoted_tags_postgresql_test() {
  lexer_test.nested_dollar_quoted_tags_postgresql_test()
}

pub fn lexer_empty_input_test() {
  lexer_test.empty_input_test()
}

pub fn lexer_whitespace_only_input_test() {
  lexer_test.whitespace_only_input_test()
}

pub fn lexer_unterminated_string_literal_does_not_panic_test() {
  lexer_test.unterminated_string_literal_does_not_panic_test()
}

pub fn lexer_unterminated_block_comment_does_not_panic_test() {
  lexer_test.unterminated_block_comment_does_not_panic_test()
}

pub fn lexer_unterminated_dollar_quoted_string_does_not_panic_test() {
  lexer_test.unterminated_dollar_quoted_string_does_not_panic_test()
}

pub fn lexer_only_operators_input_does_not_panic_test() {
  lexer_test.only_operators_input_does_not_panic_test()
}

pub fn schema_empty_input_produces_empty_catalog_test() {
  schema_parser_test.schema_empty_input_produces_empty_catalog_test()
}

pub fn schema_truncated_create_table_test() {
  schema_parser_test.schema_truncated_create_table_test()
}

pub fn schema_only_keyword_create_does_not_panic_test() {
  schema_parser_test.schema_only_keyword_create_does_not_panic_test()
}

pub fn schema_duplicate_table_across_files_test() {
  schema_parser_test.schema_duplicate_table_across_files_test()
}

pub fn error_to_string_includes_path_test() {
  schema_parser_test.error_to_string_includes_path_test()
}

pub fn parse_error_carries_source_path_test() {
  schema_parser_test.parse_error_carries_source_path_test()
}

pub fn init_sqlite_engine_generates_sqlite_schema_test() {
  cli_test.init_sqlite_engine_generates_sqlite_schema_test()
}

pub fn init_sqlite_native_runtime_test() {
  cli_test.init_sqlite_native_runtime_test()
}

pub fn init_mysql_engine_generates_mysql_schema_test() {
  cli_test.init_mysql_engine_generates_mysql_schema_test()
}

pub fn load_named_sql_blocks_test() {
  config_test.load_named_sql_blocks_test()
}

pub fn default_block_name_is_none_test() {
  config_test.default_block_name_is_none_test()
}

pub fn row_number_window_function_infers_int_test() {
  query_analyzer_test.row_number_window_function_infers_int_test()
}

pub fn percent_rank_window_function_infers_float_test() {
  query_analyzer_test.percent_rank_window_function_infers_float_test()
}

pub fn lag_window_function_infers_first_arg_type_test() {
  query_analyzer_test.lag_window_function_infers_first_arg_type_test()
}

pub fn ntile_window_function_infers_int_test() {
  query_analyzer_test.ntile_window_function_infers_int_test()
}

pub fn sqlc_arg_in_string_literal_ignored_test() {
  query_parser_test.sqlc_arg_in_string_literal_ignored_test()
}

pub fn sqlc_narg_in_line_comment_ignored_test() {
  query_parser_test.sqlc_narg_in_line_comment_ignored_test()
}

pub fn sqlc_slice_in_block_comment_ignored_test() {
  query_parser_test.sqlc_slice_in_block_comment_ignored_test()
}

pub fn sqlite_repeated_named_placeholder_single_param_test() {
  query_analyzer_test.sqlite_repeated_named_placeholder_single_param_test()
}

pub fn sqlite_repeated_and_distinct_placeholders_correct_index_test() {
  query_analyzer_test.sqlite_repeated_and_distinct_placeholders_correct_index_test()
}

pub fn sqlite_repeated_at_placeholder_single_param_test() {
  query_analyzer_test.sqlite_repeated_at_placeholder_single_param_test()
}

pub fn compound_query_column_count_mismatch_test() {
  query_analyzer_test.compound_query_column_count_mismatch_test()
}

pub fn compound_query_valid_union_test() {
  query_analyzer_test.compound_query_valid_union_test()
}

pub fn compound_query_except_mismatch_test() {
  query_analyzer_test.compound_query_except_mismatch_test()
}

// --- skip annotation tests ---

pub fn skip_annotation_skips_query_test() {
  query_parser_test.skip_annotation_skips_query_test()
}

pub fn skip_annotation_all_queries_skipped_test() {
  query_parser_test.skip_annotation_all_queries_skipped_test()
}

pub fn skip_annotation_middle_query_test() {
  query_parser_test.skip_annotation_middle_query_test()
}

// --- CLI tests ---

pub fn init_creates_config_file_test() {
  cli_test.init_creates_config_file_test()
}

pub fn init_creates_stub_schema_file_test() {
  cli_test.init_creates_stub_schema_file_test()
}

pub fn init_creates_stub_query_file_test() {
  cli_test.init_creates_stub_query_file_test()
}

pub fn init_does_not_overwrite_existing_stubs_test() {
  cli_test.init_does_not_overwrite_existing_stubs_test()
}

pub fn version_command_succeeds_test() {
  cli_test.version_command_succeeds_test()
}

// --- Entry-point error rewriting (#466) ---

pub fn rewrite_error_no_args_says_missing_subcommand_test() {
  entry_test.rewrite_error_no_args_says_missing_subcommand_test()
}

pub fn rewrite_error_long_flag_says_unrecognized_option_test() {
  entry_test.rewrite_error_long_flag_says_unrecognized_option_test()
}

pub fn rewrite_error_short_flag_says_unrecognized_option_test() {
  entry_test.rewrite_error_short_flag_says_unrecognized_option_test()
}

pub fn rewrite_error_version_flag_says_unrecognized_option_test() {
  entry_test.rewrite_error_version_flag_says_unrecognized_option_test()
}

pub fn rewrite_error_unknown_subcommand_says_unknown_subcommand_test() {
  entry_test.rewrite_error_unknown_subcommand_says_unknown_subcommand_test()
}

pub fn rewrite_error_passes_through_unrelated_messages_test() {
  entry_test.rewrite_error_passes_through_unrelated_messages_test()
}

pub fn rewrite_error_no_args_does_not_call_unrecognized_option_test() {
  entry_test.rewrite_error_no_args_does_not_call_unrecognized_option_test()
}
