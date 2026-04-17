import gleeunit
import gleeunit/should
import sqlode/codegen/builder

pub fn main() {
  gleeunit.main()
}

pub fn render_empty_block_test() {
  builder.empty()
  |> builder.render
  |> should.equal("")
}

pub fn render_line_test() {
  builder.line("pub fn greet() -> String {")
  |> builder.render
  |> should.equal("pub fn greet() -> String {")
}

pub fn render_lines_joined_with_newline_test() {
  builder.lines(["a", "b", "c"])
  |> builder.render
  |> should.equal("a\nb\nc")
}

pub fn render_blank_emits_empty_line_test() {
  builder.concat([builder.line("a"), builder.blank(), builder.line("b")])
  |> builder.render
  |> should.equal("a\n\nb")
}

pub fn empty_block_is_identity_under_concat_test() {
  builder.concat([builder.line("a"), builder.empty(), builder.line("b")])
  |> builder.render
  |> should.equal("a\nb")
}

pub fn concat_flattens_nested_blocks_test() {
  builder.concat([
    builder.concat([builder.line("a"), builder.line("b")]),
    builder.line("c"),
  ])
  |> builder.render
  |> should.equal("a\nb\nc")
}

pub fn indent_prepends_spaces_to_each_line_test() {
  builder.lines(["a", "b"])
  |> builder.indent(by: 2)
  |> builder.render
  |> should.equal("  a\n  b")
}

pub fn indent_leaves_empty_lines_without_trailing_whitespace_test() {
  builder.concat([builder.line("a"), builder.blank(), builder.line("b")])
  |> builder.indent(by: 4)
  |> builder.render
  |> should.equal("    a\n\n    b")
}

pub fn indent_zero_is_identity_test() {
  builder.lines(["a", "b"])
  |> builder.indent(by: 0)
  |> builder.render
  |> should.equal("a\nb")
}
