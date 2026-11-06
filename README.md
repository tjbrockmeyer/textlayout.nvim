# textlayout.nvim

A tiny layout engine for plain text. You write something that looks like
markdown, and `textlayout` renders it in a preview pane that always fits —
rows stack, columns sit side by side, grids get shrunk to the pane, and
`{meta}` groups evaluate expressions and variables.

```
{DEXTERITY=14}
{DEX=floor((DEXTERITY-10)/2)}
{NAME="Bob"}

Name | {NAME}
> DEX  | {DEXTERITY} ({DEX})

@grid [
HP {20+DEX} | AC {10+DEX}
> STR 14      | CHA 8
]
```

renders as

```
Name  Bob
DEX  14 (2)

HP 22  AC 12
STR 14 CHA 8
```

## Requirements

Neovim 0.10+ (developed against 0.12). No dependencies.

## Install

Any plugin manager; with `lazy.nvim`:

```lua
{
  dir = "~/code/textlayout",
  ft = "textlayout",
  config = function()
    require("textlayout").setup({})
  end,
}
```

Open a `.tl` / `.tlayout` file and run `:TextLayout` for a preview pane.
A `.tlmd` file renders **in place** instead: the window shows the layout, and
one keybinding swaps it back to the real text. See
[In-place rendering](#in-place-rendering-tlmd).

## Syntax

| Symbol | Meaning |
| --- | --- |
| newline | **joins** the two lines with a space — a line break is formatting, not a separator |
| `>` | **next row / next column**, at the start of a line |
| blank line | the same thing as a line holding nothing but `>` — a **blank row** |
| `\|` | **next column** — the separator of a row (horizontal) layer |
| `[` … `]` | **open/close a deeper layer**. The layer is the *opposite* kind of the layer that contains it |
| `@row` `[` … `]` | force that layer to be a **row**: its `\|` cells sit side by side |
| `@col` `[` … `]` | force that layer to be a **column**: everything inside it stacks |
| `@grid` `[` … `]` | force that layer to be a **grid**: its cells line up in rows and columns |
| `@name(arg)` | **layout directive** that retunes the group or row that follows; see [Layout directives](#layout-directives) |
| `{ … }` | **meta-text** |
| `\` | escape the next character, e.g. `\|`, `\[`, `\{`, `\*` |

The document root is a **row** (a flow), so `|` starts the next cell of the
current line and a `>` at the start of a line opens the next row. A line
containing `|` becomes a row of columns, and consecutive such lines share their
column widths.

A break is written, never implied: lines run together until a `>` or a blank
line starts a new row. That is what keeps a sentence you wrapped while writing
from breaking in the middle of the preview. A `>` must be the first
non-whitespace character of its line; whitespace after it is padding, and a `>`
anywhere else is ordinary text (`\>` writes one). Every row after the first
therefore opens with `>`, so a table needs one on every row:

Layers alternate. A `[ … ]` layer is the opposite kind of the layer that
contains it, so a layer inside a row **stacks**: inside it a `>` and a
`|` both separate stacked items. A layer inside *that* one flows again. Write
`@row` or `@col` in front of the `[` — or as the first thing inside it — when
you want to say which kind you mean.

```
Left | Middle | Right     ->   Left Middle Right
one  | two    | three           one   two   three

[alpha
 beta
 gamma] | beside          ->   alpha beside
                                beta
                                gamma

status is [OK].           ->   status is OK.
```

Concretely, since the root is a row, a layer written directly in the
document stacks:

```
[a | b]                   ->   a
                               b

@row [a | b]              ->   a b

@row [a|b
 c|d]                     ->   a b
                               c d
```

### Notes on how it renders

* **Whitespace around text is not content.** Padding at the start or end of a
  line or a cell is trimmed — including when the thing beside it was a
  `{X=1}` that rendered nothing, so `{X=1}  Name | Bob` is just `Name Bob`.
  Whitespace *between* two pieces of text is kept exactly as you wrote it, so
  `Hello [world]` keeps its space and `a   b` keeps its run. An empty cell is
  not content either: a column nothing uses takes no room at all.
* **`@row` / `@col` / `@grid` only count where they can modify a layer** —
  directly in front of a `[`, or as the first thing inside one. Anywhere else
  they are ordinary text, so prose can mention `@row` without it disappearing.
* **Consecutive `|` rows share column widths**, so this lines up without a
  grid. A blank line ends the run; set `align_columns = false` to lay every
  line out independently.
* **A cell of nothing but `-----` is a rule.** It draws across whatever
  contains it: in a column it is a horizontal line as wide as that group, in a
  row it is a vertical divider. Rules are drawn with box-drawing characters
  (`─`, `│`) and the crossings are tied together (`┼`, `┬`, `┴`, `├`, `┤`);
  `rules = "ascii"` keeps the dashes and pipes as written.
* **A cell is centred in its column** by default, headers included. The
  columns themselves are untouched — only the text inside them moves — so
  `cell_align = "left"` gives you the plain table look back, and
  `cell_align = "right"` is there for numbers.
* Indentation is stripped by the common amount across the document
  (`textlayout.nvim` behaves like `textwrap.dedent`), so you can indent a
  block for readability without shifting the output.
* Blank lines in the source stay blank lines in the output, except that
  blank lines at the very start or end of the document are trimmed
  (`trim_blank_edges = false` to keep them). A blank line and a line holding
  nothing but `>` are the same thing, so either one writes a blank row.
* A line that carries nothing but directives, or nothing but a `{X=1}`
  definition, is invisible: it starts no row of its own and leaves the rows
  around it alone. A `>` on the line after it still opens a row.
* A line that is *nothing but* meta and evaluates to nothing — a bare
  `{X=1}` — disappears instead of leaving a blank line. Turn this off with
  `drop_empty_meta_lines = false`.

## Layout directives

`@name(value)` retunes how the next group or row is laid out, without
touching the global config. These directives are available:

| Directive | Values | Effect |
| --- | --- | --- |
| `@row` | — | make the `[ … ]` that follows flow (a row) |
| `@col` | — | make the `[ … ]` that follows stack (a column) |
| `@grid` | — | make the `[ … ]` that follows a **grid**: cells that line up in rows and columns |
| `@gap(N)` | integer ≥ 0 | spaces between `\|` cells and grid columns |
| `@align(v, h)` | vertical: `top` / `center` / `bottom`; horizontal: `left` / `center` / `right` / `edges` | vertical alignment of the shorter cell, and where the row (or group, or document) sits across its spare width; on a `@grid` both values align each cell's contents |
| `@cell_align(x)` | `left` / `center` / `right` | where text sits inside its column |
| `@align_columns(b)` | `true` / `false` | whether consecutive `\|` rows share column widths |

`edges` is the CSS `space-between`: the first and last cell are pushed to the
edges of the row and the rest of the spare width is shared out between them.
`@align` takes the vertical alignment first and the horizontal one second, so
`@align(bottom, edges)` drops the shorter cell to the bottom and spreads the row
out. Leaving the first value out, as in `@align(, edges)`, changes only the
horizontal one, and a single value is read as the vertical alignment — unless it
names a horizontal one, as `@align(edges)` does.

The horizontal value places the whole block — a row, a group or a document of
prose — inside the width it was given, so `@align(, right)` pushes it to the
right; with no directive at all the renderer centres the document.

On a **`@grid`**, `@align` is about the cells: the vertical value decides where a
short cell's text sits inside its row, and the horizontal one where it sits
inside its column — grids start out `@align(top, center)`. The block itself is
not moved; `edges` is the exception, spreading the grid's columns out to the
edges of the width it was given.

A directive attaches to the next group or row and is inherited by everything
inside it, so `@gap(4)` before a layer reaches the rows the layer contains.
Several directives may share a line, or be stacked one per line — they all
attach to the same target:

```
@gap(4) @cell_align(right)
Name | Bob
DEX  | 14
```

renders as

```
Name    Bob
 DEX     14
```

A directive with nothing after it to attach to, or with a bad value, is
rendered literally and reported as a warning, like any other bad input.

## Meta-text

Anything in `{ … }` is evaluated:

| Form | Result |
| --- | --- |
| `{1+1}` | `2` |
| `{"hello "+"world"}` | `hello world` |
| `{"n=" + 3}` | `n=3` |
| `{DEXTERITY=14}` | defines a variable, renders nothing |
| `{DEX=floor((DEXTERITY-10)/2)}` | defines a derived variable |
| `{NAME="Bob"}` | defines a string variable |
| `{DEX+PROF+1}` | displays a computed value |
| `{X=1; X*2}` | statements separated by `;`, the last value renders |
| `{MISSING}` | `#UNDEF` — the group could not be evaluated |

Operators: `+ - * / % ^`, unary `-`, comparisons `== ~= < <= > >=`,
`and` / `or` / `not`, and `..` for explicit string concatenation. `+`
concatenates as soon as either side is a string.

Built-ins: `floor ceil round abs sign sqrt pow clamp min max len upper lower
str num ifelse rep pad`.

```
{floor((14-10)/2)}          -> 2
{clamp(12, 0, 10)}          -> 10
{max(3, 9, 4)}              -> 9
{len("abcd")}               -> 4
{ifelse(DEX > 0, "+" , "")} -> +
```

A `{ … }` that fails to evaluate — an unknown variable, a broken expression,
a definition that does not parse — renders as `#UNDEF` exactly where it was
written, and the reason is kept in `result.warnings` (change the marker with
`undef = "..."`). Syntax the parser cannot even identify, such as an
unterminated `{` or a half-written `@grid [`, is shown exactly as written.

Rendering never fails and never interrupts: if something unexpected does go
wrong, the pane falls back to showing the text as it is.

## Fitting into the pane

The preview renders to the width of the preview window:

* Content narrower than the pane is **centred** horizontally.
* A **grid** that is wider than the pane is **shrunk**: column widths are
  distributed proportionally (never below one column each) and cell text is
  cut with `…`. Every row of the grid stays exactly the same width, so the
  grid keeps its shape.
* Prose that is too wide is truncated with `…` by default; set
  `overflow = "wrap"` to wrap it onto extra lines instead.
* Trailing padding is stripped, so the preview never has trailing whitespace.

`:TextLayout export` renders the same document at its **natural** width into
a scratch buffer, so you can see the full text without any shrinking.

## In-place rendering (`.tlmd`)

`.tlmd` is the *reading* filetype: the document is laid out in its own window
rather than in a floating pane.

Nothing switches by itself. Press the toggle key — `<leader>tp` by default,
set `inline.toggle_key` to change it — in NORMAL mode to flip between the two
ways of reading a document:

| | |
| --- | --- |
| **preview** | one window, the whole layout |
| **split** | the real text, with the layout live in a pane beside it |

The cursor stays on the line you were on through every step: the source line
that produced the rendered line you were reading, and back again. Read the
layout full width, press once for text-with-live-preview, press again to go
back to reading.

Your file buffer is never rewritten. The preview lives in a hidden sibling
scratch buffer that is swapped into the window, so undo, `:w`, LSP, git
signs and autosave plugins keep seeing the text you actually wrote; `:w` from
the preview writes the source text, never the layout. The preview buffer is
not modifiable — no editing keys are intercepted, nothing is replayed, and
every mode keeps its ordinary meaning.

```
:TextLayout inline   " the preview on its own
:TextLayout split    " the preview in a pane beside the text
:TextLayout raw      " just the text
:TextLayout swap     " flip between the two, same as the toggle key
:TextLayout status   " off | text | preview | split
```

The pane is as wide as the layout needs, leaving at least 20 columns of text
(`inline.split_width` to pin it, `inline.split_side = "left"` to open it on
the other side). The preview re-renders whenever the source changes, and
re-fits itself when a window is resized.

Sessions keep the two apart. A preview is a scratch buffer, so `:mksession` never
records it as if it were a document: a window that was showing the layout comes
back with its document, and the layout is opened again on top of it. A session
saved with the preview on screen opens with the preview, one saved with the text
opens with the text, and one saved with both opens with both. Neovim does not
save floating windows at all, so a floating preview is never part of a session --
reopen it with `:TextLayout`.

Because it re-renders on every keystroke, a half-typed document is never an
error: it renders as much as it can, shows `#UNDEF` where a `{ … }` could not
be evaluated, and renders anything else exactly as written. Nothing is ever
raised out of the pane — the warnings behind a render are kept for
`require("textlayout.inline").warnings(bufnr)` instead of being shown.

## Commands

| Command | Effect |
| --- | --- |
| `:TextLayout` | toggle the preview (default subcommand) |
| `:TextLayout open` | open the preview |
| `:TextLayout close` | close the preview |
| `:TextLayout refresh` | re-render now |
| `:TextLayout focus` | open the pane if needed and move the cursor into it |
| `:TextLayout unfocus` | move the cursor back to the document |
| `:TextLayout export` | natural-width render in a scratch buffer |
| `:TextLayout reset` | close previews and clear variables |
| `:TextLayout inline` | show the laid-out preview in the current window |
| `:TextLayout split` | show the preview in a pane beside the real text |
| `:TextLayout raw` | show the real text, closing the pane beside it |
| `:TextLayout swap` | flip between the two (the `inline.toggle_key` action) |
| `:TextLayout status` | report `off`, `text`, `preview` or `split` |

Opening the preview leaves your cursor in the document — use
`:TextLayout focus` when you want to scroll the pane. Closing it (`q`,
`<Esc>`, `:TextLayout close`) puts you back where you were.

The preview refreshes on `TextChanged`, `TextChangedI`, `TextChangedP` and
`BufWritePost` (debounced). Inside the preview: `q` / `<Esc>` close it,
`r` refreshes it, `s` hops back to the document without closing it.

## Configuration

```lua
require("textlayout").setup({
  width = nil,              -- pane width; nil = the preview window's width
  gap = 1,                  -- columns between `|` cells and grid columns
  align_columns = true,     -- consecutive `|` rows share column widths
  justify = nil,            -- nil centres the document; "left" | "center" | "right" | "edges"
  rules = "unicode",         -- "unicode" | "ascii" for `-----` rules
  align = "top",            -- "top" | "center" | "bottom" for shorter cells
  cell_align = "center",    -- "left" | "center" | "right" inside a column
  ellipsis = "…",
  undef = "#UNDEF",         -- what a `{ ... }` that failed to evaluate shows as
  overflow = "truncate",    -- "truncate" | "wrap"
  dedent = true,
  trim_trailing = true,
  tabstop = 4,
  drop_empty_meta_lines = true,
  trim_blank_edges = true,
  symbols = {               -- override any sigil
    col_sep = "|",
    rule = "-----",
    next = ">",
    open = "[",
    close = "]",
    escape = "\\",
    meta_open = "{",
    meta_close = "}",
    directive = "@",
  },
  env = {},                 -- variables available to every document
  inline = {
    enabled = true,
    filetypes = { "tlmd" }, -- filetypes that render in place
    toggle_key = "<leader>tp", -- NORMAL-mode key that swaps preview <-> split
    width = nil,            -- nil = the width of the window
    split_width = nil,      -- nil = as wide as the layout needs
    split_side = "right",   -- "right" | "left"
    render_filetype = "textlayout",
  },
  preview = {
    mode = "float",         -- "float" | "split"
    width = nil,            -- nil = 60% of the editor width
    border = "rounded",
    title = " textlayout ",
    close_keys = { "q", "<Esc>" },
    enter = false,          -- move the cursor into the pane when it opens
    refresh_on = { "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost" },
    debounce = 80,
  },
})
```

## Lua API

```lua
local tl = require("textlayout")

local result = tl.render(source, { width = 60 })
result.lines          -- { "Name Bob", ... } already fitted and centred
result.warnings       -- { "unknown variable 'X'" }
result.natural_width  -- width before shrinking
result.line_map       -- line_map[i] = source line that produced line i

tl.render_natural(source)      -- no shrinking, no centring
tl.render_file("sheet.tl", { width = 40 })
tl.render_buffer(0, { width = 40 })
```

The core is plain Lua and has no Neovim dependency beyond `strdisplaywidth`
(which has a built-in fallback), so `parser`, `meta`, `layout`, `render` and
`text` can be reused or tested outside the editor.

`require("textlayout.session")` keeps previews out of `:mksession`. `setup()`
installs the `SessionLoadPre`/`SessionLoadPost` autocommands (the plugin does
that already), `source_of(buf)` reports the document a preview buffer stands for,
and `restore()` puts the documents back in the windows a session restored and
returns how many of them are showing a layout again.

## Tests

```
make test          # nvim --headless -l tests/run.lua
```

599 assertions cover the expression evaluator, the parser, layout,
table alignment, shrink/centre behaviour, source-line provenance, the
preview window, in-place rendering, sessions, the shipped examples and
plugin loading.

`examples/dnd-character-sheet.tl` is a full worked example: a 5th level cleric
with computed modifiers, saving throws, proficiency markers, inventory,
weapons and spells.

## Known limits

* Truncation/wrapping happens on display columns, not on words, inside grid
  and row cells — a cell never reflows to a different width than its column.
* `align` aligns the shorter cell inside its row, and on a `@grid` both its
  values place each cell's contents; the grid itself keeps its shape.
* Variables are re-evaluated on every render; they are not persisted between
  documents (`env` in `setup()` is the shared starting point).
* While a `.tlmd` window is showing the preview it holds a scratch buffer, so
  the statusline reads `textlayout://<path>` and anything that inspects the
  *current* buffer (LSP, git signs, `:bnext`) sees the preview. Everything
  that touches the text — undo, marks, `:w` — runs against the real buffer,
  which is one `<leader>tp` away. The preview buffer is unmodifiable, so an
  accidental `i` there fails with `E21` instead of typing into a layout.
