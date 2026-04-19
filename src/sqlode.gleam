import argv
import glint
import sqlode/cli

pub fn main() -> Nil {
  cli.app()
  |> glint.run(argv.load().arguments)
}
