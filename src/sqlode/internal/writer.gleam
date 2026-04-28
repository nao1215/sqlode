import filepath
import gleam/list
import gleam/result
import simplifile

pub type GeneratedFile {
  GeneratedFile(directory: String, path: String, content: String)
}

pub type WriteError {
  DirectoryCreateError(path: String, detail: String)
  FileWriteError(path: String, detail: String)
}

pub fn write_all(files: List(GeneratedFile)) -> Result(List(String), WriteError) {
  list.try_fold(files, [], fn(written, file) {
    use _ <- result.try(
      simplifile.create_directory_all(file.directory)
      |> result.map_error(fn(_) {
        DirectoryCreateError(
          path: file.directory,
          detail: "Failed to create directory",
        )
      }),
    )

    let full_path = filepath.join(file.directory, file.path)

    use _ <- result.try(
      simplifile.write(full_path, file.content)
      |> result.map_error(fn(_) {
        FileWriteError(path: full_path, detail: "Failed to write file")
      }),
    )

    Ok([full_path, ..written])
  })
  |> result.map(list.reverse)
}

pub fn error_to_string(error: WriteError) -> String {
  case error {
    DirectoryCreateError(path:, detail:) ->
      "Failed to create directory " <> path <> ": " <> detail
    FileWriteError(path:, detail:) ->
      "Failed to write file " <> path <> ": " <> detail
  }
}
