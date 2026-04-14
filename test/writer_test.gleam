import gleam/list
import gleam/string
import gleeunit/should
import simplifile
import sqlode/writer

const test_dir = "test_output/writer_test"

fn cleanup() {
  let _ = simplifile.delete(test_dir)
  Nil
}

pub fn write_all_creates_files_test() {
  cleanup()
  let files = [
    writer.GeneratedFile(
      directory: test_dir,
      path: "hello.gleam",
      content: "pub fn main() { Nil }",
    ),
  ]

  let assert Ok(written) = writer.write_all(files)

  written |> should.equal([test_dir <> "/hello.gleam"])

  let assert Ok(content) = simplifile.read(test_dir <> "/hello.gleam")
  content |> should.equal("pub fn main() { Nil }")

  cleanup()
}

pub fn write_all_creates_directory_test() {
  cleanup()
  let nested = test_dir <> "/sub/dir"
  let files = [
    writer.GeneratedFile(
      directory: nested,
      path: "file.gleam",
      content: "// test",
    ),
  ]

  let assert Ok(_) = writer.write_all(files)

  let assert Ok(content) = simplifile.read(nested <> "/file.gleam")
  content |> should.equal("// test")

  cleanup()
}

pub fn write_all_multiple_files_test() {
  cleanup()
  let files = [
    writer.GeneratedFile(directory: test_dir, path: "a.gleam", content: "// a"),
    writer.GeneratedFile(directory: test_dir, path: "b.gleam", content: "// b"),
    writer.GeneratedFile(directory: test_dir, path: "c.gleam", content: "// c"),
  ]

  let assert Ok(written) = writer.write_all(files)

  list.length(written) |> should.equal(3)

  let assert Ok(a) = simplifile.read(test_dir <> "/a.gleam")
  a |> should.equal("// a")
  let assert Ok(c) = simplifile.read(test_dir <> "/c.gleam")
  c |> should.equal("// c")

  cleanup()
}

pub fn write_all_empty_list_test() {
  cleanup()
  let assert Ok(written) = writer.write_all([])
  written |> should.equal([])
  cleanup()
}

pub fn write_all_returns_paths_in_order_test() {
  cleanup()
  let files = [
    writer.GeneratedFile(directory: test_dir, path: "first.gleam", content: ""),
    writer.GeneratedFile(directory: test_dir, path: "second.gleam", content: ""),
  ]

  let assert Ok(written) = writer.write_all(files)

  written
  |> should.equal([
    test_dir <> "/first.gleam",
    test_dir <> "/second.gleam",
  ])

  cleanup()
}

pub fn write_all_trailing_slash_directory_test() {
  cleanup()
  let dir_with_slash = test_dir <> "/"
  let files = [
    writer.GeneratedFile(
      directory: dir_with_slash,
      path: "trailing.gleam",
      content: "// trailing slash test",
    ),
  ]

  let assert Ok(written) = writer.write_all(files)

  // filepath.join normalizes the path — no double slash
  written |> should.equal([test_dir <> "/trailing.gleam"])

  let assert Ok(content) = simplifile.read(test_dir <> "/trailing.gleam")
  content |> should.equal("// trailing slash test")

  cleanup()
}

pub fn error_to_string_directory_error_test() {
  let error =
    writer.DirectoryCreateError(path: "/bad/path", detail: "Permission denied")
  writer.error_to_string(error)
  |> string.contains("Failed to create directory /bad/path")
  |> should.be_true()
}

pub fn error_to_string_file_error_test() {
  let error =
    writer.FileWriteError(path: "/bad/file.gleam", detail: "Disk full")
  writer.error_to_string(error)
  |> string.contains("Failed to write file /bad/file.gleam")
  |> should.be_true()
}
