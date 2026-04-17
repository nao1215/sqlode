//// Minimal line-oriented builder for emitting generated Gleam source code.
////
//// A `Block` is an ordered list of already-rendered lines.  Callers stitch
//// blocks together with `concat`, add blank separators with `blank`, and
//// attach leading indentation with `indent`.  `render` flattens a block to
//// the final `String` by joining on `"\n"`.
////
//// The builder intentionally does not try to model reflow (Wadler-style
//// `Doc`) — generated Gleam code is layout-deterministic and lists of
//// lines are the idiom already used across the codegen modules.

import gleam/list
import gleam/string

pub opaque type Block {
  Block(lines: List(String))
}

/// A block containing no lines at all. Useful for conditional sections.
pub fn empty() -> Block {
  Block([])
}

/// A block containing a single line of text.
pub fn line(value: String) -> Block {
  Block([value])
}

/// A block from an explicit list of pre-split lines.
pub fn lines(values: List(String)) -> Block {
  Block(values)
}

/// A block containing a single empty line, used as a visual separator.
pub fn blank() -> Block {
  Block([""])
}

/// Concatenate the lines of several blocks in order.
pub fn concat(parts: List(Block)) -> Block {
  Block(list.flat_map(parts, fn(b) { b.lines }))
}

/// Prepend `by` spaces to every non-empty line in the block.
/// Empty lines stay empty so the output never has trailing whitespace.
pub fn indent(block: Block, by by: Int) -> Block {
  let prefix = string.repeat(" ", by)
  Block(
    list.map(block.lines, fn(l) {
      case l {
        "" -> ""
        _ -> prefix <> l
      }
    }),
  )
}

/// Render the block by joining its lines with newlines.
pub fn render(block: Block) -> String {
  string.join(block.lines, "\n")
}
