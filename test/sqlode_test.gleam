import codegen_test
import config_test
import gleeunit
import query_parser_test

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

pub fn render_queries_module_test() {
  codegen_test.render_queries_module_test()
}
