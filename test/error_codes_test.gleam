import gleam/list
import gleam/regexp
import gleam/set
import gleam/string
import gleeunit/should
import simplifile

// Every error code the CLI can print has an entry in doc/errors.md, and
// every entry there names a code the CLI still prints. A new error
// cannot ship without a documented code, and a removed one does not
// leave a stale entry behind.
pub fn error_codes_match_the_reference_test() {
  let assert Ok(code_pattern) = regexp.from_string("SQD[0-9]{4}")
  let assert Ok(files) = simplifile.get_files(in: "src")
  let in_source =
    files
    |> list.filter(string.ends_with(_, ".gleam"))
    |> list.flat_map(fn(path) {
      let assert Ok(content) = simplifile.read(path)
      regexp.scan(code_pattern, content) |> list.map(fn(m) { m.content })
    })
    |> set.from_list

  let assert Ok(heading_pattern) =
    regexp.compile(
      "^## (SQD[0-9]{4})$",
      regexp.Options(case_insensitive: False, multi_line: True),
    )
  let assert Ok(reference) = simplifile.read("doc/errors.md")
  let headings =
    regexp.scan(heading_pattern, reference)
    |> list.map(fn(m) { m.content |> string.drop_start(3) })

  // A code is documented once.
  list.length(headings) |> should.equal(set.size(set.from_list(headings)))

  set.to_list(set.difference(in_source, set.from_list(headings)))
  |> should.equal([])
  set.to_list(set.difference(set.from_list(headings), in_source))
  |> should.equal([])
  { set.size(in_source) > 0 } |> should.be_true
}
