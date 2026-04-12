import argv
import glint
import sqlode/cli

pub fn main() {
  cli.app()
  |> glint.run(argv.load().arguments)
}
