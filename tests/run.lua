-- tests/run.lua
-- Headless test suite:  nvim --headless -l tests/run.lua
--
-- No dependencies; every case runs against the real modules.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local text = require("textlayout.text")
local meta = require("textlayout.meta")
local parser = require("textlayout.parser")
local layout = require("textlayout.layout")
local render = require("textlayout.render")
local textlayout = require("textlayout")

local passed, failed = 0, 0
local failures = {}
local current_group = "?"

local function group(name)
  current_group = name
end

local function fail(msg)
  failed = failed + 1
  failures[#failures + 1] = current_group .. ": " .. msg
  io.write("  FAIL " .. current_group .. ": " .. msg .. "\n")
end

local function ok(cond, msg)
  if cond then
    passed = passed + 1
  else
    fail(msg or "assertion failed")
  end
end

local function eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
  else
    fail(
      string.format(
        "%s\n      expected: %s\n      actual:   %s",
        msg or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function lines_eq(actual, expected, msg)
  local a = table.concat(actual, "\n")
  local e = table.concat(expected, "\n")
  if a == e then
    passed = passed + 1
  else
    fail(string.format("%s\n      expected:\n%s\n      actual:\n%s", msg or "lines differ", e, a))
  end
end

local function render_lines(src, opts)
  return render.render(src, opts).lines
end

----------------------------------------------------------------------
group("text: display width")
----------------------------------------------------------------------

eq(text.dwidth(""), 0, "empty string")
eq(text.dwidth("abc"), 3, "ascii")
eq(text.dwidth("héllo"), 5, "combining-free latin-1")
eq(text.dwidth("日本"), 4, "wide characters")
eq(text.pad_right("ab", 5), "ab   ", "pad right")
eq(text.pad_left("ab", 5), "   ab", "pad left")
eq(text.center("ab", 6), "  ab  ", "center")
eq(text.clip("abcdef", 3), "abc", "clip")
eq(text.truncate("abcdef", 4), "abc…", "truncate with ellipsis")
eq(text.truncate("abc", 4), "abc", "truncate no-op")
eq(text.truncate("日本語です", 5), "日本…", "truncate wide")

----------------------------------------------------------------------
group("meta: expressions")
----------------------------------------------------------------------

local function ev(src, env)
  local v, err = meta.eval(src, env or {})
  if err then
    return "ERR:" .. err
  end
  return meta.fmt(v)
end

eq(ev("1+1"), "2", "integer addition")
eq(ev("2*3+4"), "10", "precedence")
eq(ev("(2+3)*4"), "20", "parentheses")
eq(ev("10/4"), "2.5", "float division")
eq(ev("10%3"), "1", "modulo")
eq(ev("2^10"), "1024", "power")
eq(ev("-5+2"), "-3", "unary minus")
eq(ev("0.1+0.2"), "0.3", "float noise is hidden")
eq(ev('"hello "+"world"'), "hello world", "string concat with +")
eq(ev('"a".."b"'), "ab", "string concat with ..")
eq(ev('"n=" + 3'), "n=3", "number coerced to string")
eq(ev('"6" - 1'), "5", "numeric string coerced")
eq(ev("floor((14-10)/2)"), "2", "floor")
eq(ev("floor(7/2)"), "3", "floor 2")
eq(ev("ceil(7/2)"), "4", "ceil")
eq(ev("round(2.5)"), "3", "round")
eq(ev("round(-2.5)"), "-3", "round negative")
eq(ev("max(3, 9, 4)"), "9", "max")
eq(ev("min(3, 9, 4)"), "3", "min")
eq(ev("clamp(12, 0, 10)"), "10", "clamp")
eq(ev('len("abcd")'), "4", "len")
eq(ev('upper("ab")'), "AB", "upper")
eq(ev('ifelse(1 < 2, "yes", "no")'), "yes", "ifelse")
eq(ev("1 < 2"), "true", "comparison")
eq(ev('"a" == "a"'), "true", "string equality")
eq(ev("1 == 1.0"), "true", "numeric equality")
eq(ev("true and 5"), "5", "and")
eq(ev("false or 5"), "5", "or")
eq(ev("not false"), "true", "not")

----------------------------------------------------------------------
group("meta: variables")
----------------------------------------------------------------------

local env = {}
eq(ev("DEXTERITY=14", env), "", "assignment renders nothing")
eq(env.DEXTERITY, 14, "assignment stored")
eq(ev("DEX=floor((DEXTERITY-10)/2)", env), "", "derived assignment")
eq(env.DEX, 2, "derived value")
eq(ev("DEX+PROF+1", setmetatable({ PROF = 3 }, { __index = env })), "6", "lookup through parent env")
eq(ev("NAME=\"Bob\"", env), "", "string assignment")
eq(ev("NAME", env), "Bob", "string lookup")
eq(ev("X=1; X*2", {}), "2", "statement sequencing")
eq(ev("MISSING", {}), "ERR:unknown variable 'MISSING'", "unknown variable errors")

local warnings = {}
local res = render.render("a {MISSING} b", { width = nil })
eq(#res.warnings, 1, "unknown variable produces a warning")
eq(res.lines[1], "a #UNDEF b", "a group that fails to evaluate shows #UNDEF")

----------------------------------------------------------------------
group("meta: errors")
----------------------------------------------------------------------

ok(select(2, meta.eval("1 +")) ~= nil, "trailing operator errors")
ok(select(2, meta.eval("(1")) ~= nil, "unbalanced paren errors")
ok(select(2, meta.eval('"abc')) ~= nil, "unterminated string errors")
ok(select(2, meta.eval("$")) ~= nil, "bad character errors")

----------------------------------------------------------------------
group("parser: structure")
----------------------------------------------------------------------

local function parse(src, opts)
  return parser.parse(src, opts)
end

local ast = parse("hello")
eq(ast.type, "box", "root is a box")
eq(ast.dir, "col", "root stacks vertically")
eq(#ast.children, 1, "one line")
eq(ast.children[1].type, "text", "line is text")

ast = parse("a\n> b")
eq(#ast.children, 2, "two rows")
eq(ast.children[1].parts[1].value, "a", "first row")
eq(ast.children[2].parts[1].value, "b", "second row")

ast = parse("a|b")
eq(ast.children[1].type, "box", "columns make a row box")
eq(ast.children[1].dir, "row", "row direction")
eq(#ast.children[1].children, 2, "two columns")

ast = parse("a|b\n> c|d")
eq(#ast.children, 2, "two rows of two")
eq(#ast.children[1].children, 2, "row 1 has two cells")
eq(#ast.children[2].children, 2, "row 2 has two cells")

ast = parse("[a|b]")
eq(ast.children[1].type, "box", "group becomes a node")
eq(ast.children[1].dir, "col", "a layer inside a flow stacks")
eq(ast.children[1].children[1].parts[1].value, "a", "first stacked item")
eq(ast.children[1].children[2].parts[1].value, "b", "second stacked item")

ast = parse("@row [a|b]")
eq(ast.children[1].children[1].dir, "row", "@row forces the layer to flow")

ast = parse("[@row a|b]")
eq(ast.children[1].children[1].dir, "row", "@row first inside the layer works too")

ast = parse("[[a|b]]")
eq(ast.children[1].dir, "col", "the first layer stacks")
eq(ast.children[1].children[1].children[1].dir, "row", "the second layer flows, so its line is a row")

ast = parse("\\|a\\[b\\]")
eq(ast.children[1].parts[1].value, "|a[b]", "escapes are literal")

ast = parse("x{1+1}y")
local parts = ast.children[1].parts
eq(#parts, 3, "text meta text split into three parts")
eq(parts[1].value, "x", "leading text")
eq(parts[2].kind, "expr", "middle is an expression")
eq(parts[3].value, "y", "trailing text")

local blank = parse("a\n\n> b")
eq(#blank.children, 3, "blank line preserved")
eq(blank.children[2].type, "text", "blank line is empty text")

eq(#parse("a\n").children, 1, "trailing newline does not add a row")

local indented = parse("    a\n>     b")
eq(indented.children[1].parts[1].value, "a", "common indentation removed")

local grid = parse("@grid [\n> a|b\n> c|d\n]").children[1]
eq(grid.type, "grid", "grid node")
eq(grid.rows, 2, "grid rows")
eq(grid.cols, 2, "grid cols")
eq(#grid.children, 4, "four cells")

----------------------------------------------------------------------
group("line breaks: a break is written, not implied")
----------------------------------------------------------------------

lines_eq(render_lines("a\nb"), { "a b" }, "a line break joins the two lines")
lines_eq(render_lines("a\n   b"), { "a b" }, "and the padding around it is not content")
lines_eq(render_lines("a\n> b"), { "a", "b" }, "a > at the start of a line opens the next row")
lines_eq(render_lines("> a | b"), { "a b" }, "a > on the first line just opens the first row")
lines_eq(render_lines("a > b"), { "a > b" }, "a > inside a line is ordinary text")
lines_eq(render_lines("a \\> b"), { "a > b" }, "and it can be escaped")
lines_eq(render_lines("a\n\n> b"), { "a", "", "b" }, "a blank line is still a break of its own")
lines_eq(
  render_lines("a\n; b", { symbols = { next = ";" } }),
  { "a", "b" },
  "the break character can be changed"
)
lines_eq(render_lines("a\n> b", { symbols = { next = ";" } }), { "a > b" }, "and then > is just text")
lines_eq(
  render_lines("Name | Bob\n> DEX  | 14"),
  { "Name Bob", "DEX  14" },
  "a table needs > on every row but the first"
)

----------------------------------------------------------------------
group("blank lines: a blank line and a lone > are the same thing")
----------------------------------------------------------------------

lines_eq(render_lines("> hi\n>\n> world"), { "hi", "", "world" }, "a lone > is a blank line")
lines_eq(render_lines("> hi\n\n> world"), { "hi", "", "world" }, "and so is a blank line: the two are the same")
lines_eq(render_lines("a\n>\nb"), { "a", "", "b" }, "a lone > between two lines is a blank row")
lines_eq(render_lines("a\n\nb"), { "a", "", "b" }, "exactly as a blank line is")
lines_eq(render_lines("a\n>   \nb"), { "a", "", "b" }, "padding after the > is not content")
lines_eq(render_lines("a\n   \nb"), { "a", "", "b" }, "and padding on a blank line is not either")
lines_eq(render_lines("[a\n\nb]"), { "a", "", "b" }, "a blank line is a blank row in a layer too")
lines_eq(render_lines("[a\n>\nb]"), { "a", "", "b" }, "and a lone > is the same there")

-- A line that carries nothing but directives, or nothing but a definition, is
-- invisible: it starts no row of its own and leaves the rows around it alone.
lines_eq(render_lines("a\n@row\nb"), { "a b" }, "a line of nothing but directives is invisible")
lines_eq(render_lines("a\n{X=1}\nb"), { "a b" }, "and so is a line of nothing but a definition")
lines_eq(render_lines("a\n@row\n> b"), { "a", "b" }, "a break character after an invisible line still opens a row")
lines_eq(render_lines("a\n{X=1}\n> b"), { "a", "b" }, "and so does one after a definition")
lines_eq(
  render_lines("a\n@align(center)\n> b\n> c"),
  { "a", "b", "c" },
  "invisible lines leave the rows around them alone"
)

group("layout: natural sizing")
----------------------------------------------------------------------

lines_eq(render_lines("hello"), { "hello" }, "single line")
lines_eq(render_lines("a\n> b"), { "a", "b" }, "stacked rows")
lines_eq(render_lines("a|b"), { "a b" }, "two columns, one space gap")
lines_eq(render_lines("aa|b\n> c|dd"), { "aa b", "c  dd" }, "columns are width-aligned")
lines_eq(render_lines("a|b\n> ccc|d"), { " a  b", "ccc d" }, "cells are centred in their column by default")
lines_eq(
  render_lines("a|b\n> ccc|d", { cell_align = "left" }),
  { "a   b", "ccc d" },
  "cell_align = left keeps the old look"
)
lines_eq(render_lines("a|b\n> ccc|d", { cell_align = "right" }), { "  a b", "ccc d" }, "cell_align = right")
lines_eq(
  render_lines("@grid [\n> a|b\n> ccc|d\n]", { cell_align = "left" }),
  { "a   b", "ccc d" },
  "grids follow cell_align too"
)
lines_eq(
  render_lines("Name | Bob\n> DEX  | 14\n> CON  | 12"),
  { "Name Bob", "DEX  14", "CON  12" },
  "consecutive rows share column widths"
)
lines_eq(
  render_lines("Name | Bob\n> DEX  | 14", { align_columns = false }),
  { "Name Bob", "DEX 14" },
  "align_columns can be turned off"
)
lines_eq(
  render_lines("a|b\n\n> c|dd"),
  { "a b", "", "c dd" },
  "a blank line breaks the table run"
)
lines_eq(render_lines("a|[b\n> c]"), { "a b", "  c" }, "nested stack inside a row")
lines_eq(render_lines("@row [a|b\n> c|d]"), { "a b", "c d" }, "@row keeps a table inside a layer")
lines_eq(render_lines("Hello [world]"), { "Hello world" }, "juxtaposition has no gap")
lines_eq(render_lines("a|b", { gap = 3 }), { "a   b" }, "configurable gap")

lines_eq(render_lines("@grid [\n> a|b\n> c|d\n]"), { "a b", "c d" }, "2x2 grid")
lines_eq(
  render_lines("@grid [\n> HP 12 | AC 15 | SPD 30\n> STR 14 | DEX 14 | CON 12\n]"),
  { "HP 12  AC 15  SPD 30", "STR 14 DEX 14 CON 12" },
  "2x3 grid aligns columns"
)
lines_eq(render_lines("@grid [\n> a|b|c\n]"), { "a b c" }, "1-row grid")
lines_eq(render_lines("@grid [\n> a\n> b\n> c\n]"), { "a", "b", "c" }, "1-column grid")

lines_eq(
  render_lines("@grid [\n> a | b\n> c\n]"),
  { "a b", "c" },
  "a ragged grid pads its short rows so the columns still line up"
)
lines_eq(
  render_lines("@grid [\n> a | b | c\n> d | e | f\n> g | h | i\n]"),
  { "a b c", "d e f", "g h i" },
  "a 3x3 grid keeps its shape"
)
lines_eq(
  render_lines("@grid [\n> a | @grid [\n> b | c\n> d | e\n> ] | f\n]"),
  { "a b c f", "  d e" },
  "a @grid nested inside a cell is a grid too"
)
lines_eq(
  render_lines("@grid [\n> [a\n> b] | X\n]"),
  { "a X", "b" },
  "a plain subdivision inside a grid cell stacks as usual"
)
lines_eq(
  render_lines("@grid [\n> a | b\n> cc | d\n]"),
  { "a  b", "cc d" },
  "grid cells are centred in their columns by default"
)
lines_eq(
  render_lines("@align(top, center)\n> @grid [\n> a | b\n> cc | d\n]"),
  { "a  b", "cc d" },
  "the default cell alignment is top / centre"
)
lines_eq(
  render_lines("@align(, right)\n> @grid [\n> a | b\n> cc | d\n]"),
  { " a b", "cc d" },
  "@align on a grid aligns the cells' contents, not the block"
)
lines_eq(render_lines("@grid [\n> a | b\n]"), { "a b" }, "@grid in front of a layer opens a grid")
lines_eq(render_lines("use @grid to build a table"), { "use @grid to build a table" }, "@grid in prose stays literal")

----------------------------------------------------------------------
group("whitespace")
----------------------------------------------------------------------

lines_eq(render_lines("  hello  "), { "hello" }, "padding around a line is not content")
lines_eq(
  render_lines("  hello\n> world"),
  { "hello", "world" },
  "indentation that dedent cannot remove is not content either"
)
lines_eq(render_lines("a   b"), { "a   b" }, "whitespace between two words is kept as written")
lines_eq(render_lines("{X=1}  Name | Bob  "), { "Name Bob" }, "a dropped group leaves no padding behind")
lines_eq(render_lines("Name {X=1}"), { "Name" }, "a dropped group leaves no trailing space")
lines_eq(render_lines("{X=1}   "), { "" }, "a line of nothing but meta and spaces disappears")
lines_eq(render_lines("   | a"), { "a" }, "an empty first column leaves no gap")
lines_eq(render_lines("a |"), { "a" }, "an empty last column leaves no gap")
lines_eq(
  render_lines("@grid [\n> {X=1}  a | b\n> c | d\n]"),
  { "a b", "c d" },
  "grid cells are trimmed after their meta is dropped"
)
lines_eq(
  render_lines("@grid [\n> {X=1} | b\n> c | d\n]"),
  { "  b", "c d" },
  "an empty cell keeps its column when a neighbour fills it"
)

----------------------------------------------------------------------
group("nesting: layers alternate row and col")
----------------------------------------------------------------------

-- The document root is a flow (a row container): `|` starts the next cell of
-- the same line and a newline starts a new line.
lines_eq(render_lines("a | b"), { "a b" }, "the root is a flow")
lines_eq(render_lines("a|b\n> c|d"), { "a b", "c d" }, "the root shares column widths")

-- A `[ ]` layer inside a flow is a stack: both a newline and a `|` separate
-- stacked items, so pipes separate the rows of the layer.
lines_eq(render_lines("[a | b]"), { "a", "b" }, "a layer inside a flow stacks")
lines_eq(render_lines("[a\n> b]"), { "a", "b" }, "newlines stack inside a layer too")
lines_eq(render_lines("[a|b\n> c|d]"), { "a", "b", "c", "d" }, "pipes stack inside a layer")
lines_eq(render_lines("[a\n\n> b]"), { "a", "", "b" }, "a blank line survives in a layer")

-- A `[ ]` layer inside a stack flows again, so kinds alternate with depth.
lines_eq(render_lines("[[a | b]]"), { "a b" }, "layers alternate with depth")
lines_eq(render_lines("[a\n> @row [b | c]]"), { "a", "b c" }, "a layer inside a stack flows")

-- Explicit markers override the alternation.
lines_eq(render_lines("@row [a | b]"), { "a b" }, "@row forces a flow")
lines_eq(render_lines("@col [a | b]"), { "a", "b" }, "@col forces a stack")
lines_eq(render_lines("@row [a|b\n> c|d]"), { "a b", "c d" }, "@row brings a table back")
lines_eq(render_lines("[[@col a | b]]"), { "a", "b" }, "@col overrides the alternation")
lines_eq(render_lines("@col [\n> a|b]"), { "a", "b" }, "a directive line adds no content")

-- A layer keeps behaving like before when its parent is already a flow, so
-- the usual "stack inside a row cell" still works.
lines_eq(render_lines("x | [a | b]"), { "x a", "  b" }, "a layer beside a cell stacks in the row")
lines_eq(
  render_lines("[alpha\n> beta] | beside"),
  { "alpha beside", "beta" },
  "a layer used as a row cell is unchanged"
)

-- Markers inside grid cells work too.
lines_eq(render_lines("@grid [\n> @row [a|b] | c\n]"), { "a b c" }, "@row inside a grid cell")
lines_eq(render_lines("@grid [\n> @col [a|b] | c\n]"), { "a c", "b" }, "@col inside a grid cell")

-- A directive only means something where it can modify a layer, so the same
-- word in ordinary prose stays text.
lines_eq(render_lines("@rows a | b"), { "@rows a b" }, "an unknown @word stays literal")
lines_eq(render_lines("use @row to flow"), { "use @row to flow" }, "@row in prose stays literal")
lines_eq(render_lines("[a @col b]"), { "a @col b" }, "@col that is not first stays literal")
lines_eq(render_lines("@row\n> [a | b]"), { "a b" }, "@row on its own line reaches the next layer")

----------------------------------------------------------------------
group("broken input")
----------------------------------------------------------------------

-- Whatever half-finished thing is on screen, a render must produce lines and
-- must not raise: the pane is re-rendered on every keystroke.
local broken = {
  "[",
  "[a",
  "[a|b",
  "{",
  "{1+",
  "{X=",
  '{NAME="Bob}',
  "]",
  "a]b",
  "][",
  "@grid(2",
  "@grid(2,2)",
  "@grid [\na",
  "@gap(",
  "@gap(x) a",
  "@align(nope) a",
  "@row",
  "@col [a | b",
  "[[[[[[[[[[[[a",
  "@grid [\n[[a",
  "\\",
  "\\{",
  "{1+1}{",
}
for _, src in ipairs(broken) do
  local fine, res = pcall(render.render, src, { width = 40 })
  ok(fine, "render survives " .. string.format("%q", src) .. ": " .. tostring(res))
  if fine then
    ok(#res.lines > 0, "render produces a line for " .. string.format("%q", src))
  end
end

lines_eq(render_lines("{MISSING}"), { "#UNDEF" }, "an unknown variable shows #UNDEF")
lines_eq(render_lines("{1+}"), { "#UNDEF" }, "a broken expression shows #UNDEF")
lines_eq(render_lines("{X=}"), { "#UNDEF" }, "a broken definition shows #UNDEF")
lines_eq(render_lines("a {MISSING} b"), { "a #UNDEF b" }, "#UNDEF sits where the group was")
lines_eq(render_lines("Name | {NOPE}"), { "Name #UNDEF" }, "#UNDEF lines up in a table")
lines_eq(render_lines("{MISSING}", { undef = "??" }), { "??" }, "the marker is configurable")
lines_eq(render_lines("{"), { "{" }, "an unterminated group is still literal")
lines_eq(render_lines("@grid(2"), { "@grid(2" }, "a malformed directive is still literal")
lines_eq(render_lines("a [b"), { "a b" }, "an unclosed layer still renders its content")

----------------------------------------------------------------------
group("layout: fitting to a pane")
----------------------------------------------------------------------

local out = render_lines("abcdefghij", { width = 5 })
eq(text.dwidth(out[1]), 5, "long line is clipped to the pane")
eq(out[1], "abcd…", "clipping uses an ellipsis")

out = render_lines("ab", { width = 6 })
eq(out[1], "  ab", "short content is centred")
eq(text.dwidth(out[1]), 4, "centred content is not right-padded")

out = render_lines("abcdef", { width = 6 })
eq(out[1], "abcdef", "exact fit is untouched")

out = render_lines("@grid [\n> hello world|goodbye moon\n]", { width = 20 })
eq(text.dwidth(out[1]), 20, "grid row fits the pane")

out = render_lines("@grid [\n> 1111|2222\n> 3333|4444\n]", { width = 9 })
eq(text.dwidth(out[1]), 9, "grid is shrunk to the pane")
eq(text.dwidth(out[2]), 9, "all grid rows are the same width")

local natural = render.render("@grid [\n> hello|world\n]", { width = nil })
eq(natural.lines[1], "hello world", "natural render ignores the pane")

----------------------------------------------------------------------
group("meta in layout")
----------------------------------------------------------------------

lines_eq(render_lines("{1+1}"), { "2" }, "expression renders")
lines_eq(render_lines('{"a"+"b"}'), { "ab" }, "string expression renders")
lines_eq(render_lines("{X=5}{X*2}"), { "10" }, "assignment then display")
lines_eq(
  render_lines("{DEXTERITY=14}\n> {DEX=floor((DEXTERITY-10)/2)}\n> DEX | {DEX}"),
  { "DEX 2" },
  "assignment-only lines disappear"
)
lines_eq(
  render_lines("kept\n> {X=2}\n> more", { drop_empty_meta_lines = false }),
  { "kept", "", "more" },
  "drop_empty_meta_lines can be turned off"
)
lines_eq(
  render_lines("\n\n> kept\n\n"),
  { "kept" },
  "blank edges are trimmed"
)
lines_eq(
  render_lines("\n> kept\n", { trim_blank_edges = false }),
  { "", "kept" },
  "trim_blank_edges can be turned off"
)
lines_eq(render_lines("a\n\n> b"), { "a", "", "b" }, "blank source lines are kept")
lines_eq(render_lines("{NAME=\"Bob\"}\n> Hi {NAME}"), { "Hi Bob" }, "variable in a row")
lines_eq(
  render_lines("{N=3}\n> @grid [\n> {N}|{N*2}|{N*3}\n]"),
  { "3 6 9" },
  "meta inside grid cells"
)

----------------------------------------------------------------------
group("integration")
----------------------------------------------------------------------

textlayout.setup({})
local r = textlayout.render("a|b", { width = 10 })
eq(#r.lines, 1, "setup + render works")
eq(r.lines[1], "   a b", "content is centred inside the pane")

local example = table.concat({
  "{DEXTERITY=14}",
  "{DEX=floor((DEXTERITY-10)/2)}",
  "{PROF=2}",
  "Attack | {DEX+PROF}",
}, "\n")
local er = textlayout.render(example, { width = 20 })
eq(er.lines[1], "      Attack 4", "example document renders centred in the pane")

----------------------------------------------------------------------


----------------------------------------------------------------------
group("preview pane")
----------------------------------------------------------------------

local preview = require("textlayout.preview")

local function preview_lines(buf)
  local win = preview.win_for(buf)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function with_buffer(lines, fn)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ok_, err = pcall(fn, buf)
  pcall(preview.close, buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok_ then
    fail("error: " .. tostring(err))
  end
end

with_buffer({ "a|b", "> ccc|d" }, function(buf)
  local win = preview.open(buf)
  ok(win ~= nil and vim.api.nvim_win_is_valid(win), "preview window opens")
  ok(preview.is_open(buf), "preview reports open")

  local pane = vim.api.nvim_win_get_width(win)
  local got = preview_lines(buf)
  eq(#got, 2, "preview has one line per source row")
  eq(vim.trim(got[1]), "a  b", "preview renders columns")
  ok(text.dwidth(got[1]) <= pane, "preview line fits the pane")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
  preview.refresh(buf)
  eq(vim.trim(preview_lines(buf)[1]), "changed", "refresh picks up edits")

  preview.close(buf)
  ok(not preview.is_open(buf), "preview closes")
  ok(not vim.api.nvim_win_is_valid(win), "preview window is gone")
end)

with_buffer({ "@grid [", "aaa|bbb", "> ccc|ddd", "]" }, function(buf)
  local win = preview.open(buf)
  local pane = vim.api.nvim_win_get_width(win)
  local got = preview_lines(buf)
  eq(#got, 2, "grid renders two rows")
  for _, line in ipairs(got) do
    ok(text.dwidth(line) <= pane, "grid row fits the pane")
  end
end)

with_buffer({ "{X=2}", "X is {X}" }, function(buf)
  preview.open(buf)
  eq(vim.trim(preview_lines(buf)[1]), "X is 2", "meta evaluates in the preview")
end)

with_buffer({ "a|b" }, function(buf)
  local win = preview.open(buf)
  ok(vim.api.nvim_get_current_win() ~= win, "open leaves the cursor in the document")
  preview.focus(buf)
  eq(vim.api.nvim_get_current_win(), win, "focus moves the cursor into the pane")
  preview.unfocus(buf)
  ok(vim.api.nvim_get_current_win() ~= win, "unfocus moves the cursor back")
end)

with_buffer({ "a|b" }, function(buf)
  local win = preview.open(buf, { enter = true })
  eq(vim.api.nvim_get_current_win(), win, "open with enter focuses the pane")
end)

with_buffer({ "a|b" }, function(buf)
  preview.focus(buf)
  eq(preview.win_for(), preview.win_for(buf), "commands run inside the pane resolve to the document")
  preview.toggle()
  ok(not preview.is_open(buf), "toggle from inside the pane closes it")
end)

with_buffer({ "a|b" }, function(buf)
  local out = preview.export(buf)
  eq(vim.api.nvim_buf_get_lines(out, 0, -1, false)[1], "a b", "export renders at natural width")
end)


----------------------------------------------------------------------
group("source line provenance")
----------------------------------------------------------------------

local function token_lines(src)
  local toks = parser.tokenize(parser.normalize(src, {}), parser.default_symbols, function() end)
  local out = {}
  for _, t in ipairs(toks) do
    if t.t == "text" then
      out[#out + 1] = t.line
    end
  end
  return out
end

eq(table.concat(token_lines("one\n> two\n> three"), ","), "1,2,3", "tokens carry their source line")

local spanning = parser.tokenize(parser.normalize("a {1 +\n2} b", {}), parser.default_symbols, function() end)
local kinds = {}
for _, t in ipairs(spanning) do
  kinds[#kinds + 1] = t.t .. "@" .. tostring(t.line)
end
eq(table.concat(kinds, " "), "text@1 meta@1 text@2 eof@nil", "a meta group that spans lines does not skew the counter")

local numbered = render.render(table.concat({
  "Title", -- 1
  "", -- 2, orphaned by the drop below
  "{N=2}", -- 3, a bare definition, so dropped
  "> A | B", -- 4
  "> C | D", -- 5
}, "\n"), {})
lines_eq(numbered.lines, { "Title", "A B", "C D" }, "definitions and their blank line disappear")
eq(#numbered.line_map, #numbered.lines, "line_map matches the rendered lines")
eq(numbered.line_map[1], 1, "prose keeps its source line")
eq(numbered.line_map[2], 4, "the first table row keeps its source line")
eq(numbered.line_map[3], 5, "the second table row keeps its source line")

local gridded = render.render(table.concat({
  "@grid [", -- 1
  "> a | b", -- 2
  "> c | d", -- 3
  "]", -- 4
}, "\n"), {})
eq(gridded.line_map[1], 2, "grid row 1 points at its first cell")
eq(gridded.line_map[2], 3, "grid row 2 points at its first cell")

local wrapped = render.render("the quick brown fox", { width = 6, overflow = "wrap" })
eq(#wrapped.line_map, #wrapped.lines, "wrapped lines are mapped too")
for i = 1, #wrapped.lines do
  eq(wrapped.line_map[i], 1, "every wrapped row maps back to line 1")
end

local nested = render.render("left | [a\n> b]", {})
eq(#nested.line_map, #nested.lines, "a nested layer is mapped")
ok(nested.line_map[1] == 1, "a row containing a layer maps to that row")


----------------------------------------------------------------------
group("inline rendering")
----------------------------------------------------------------------

local inline = require("textlayout.inline")

local function with_inline(lines, fn)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "tlmd"
  local ok_, err = pcall(fn, buf)
  pcall(inline.detach, buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok_ then
    fail("error: " .. tostring(err))
  end
end

ok(vim.o.hidden, "inline rendering relies on 'hidden'")

vim.cmd("enew")
local plain = vim.api.nvim_get_current_buf()
vim.bo[plain].filetype = "textlayout"
eq(inline.attach(plain), nil, "only the configured filetypes render in place")
eq(inline.status(vim.api.nvim_get_current_win()), "off", "a window with no session reports 'off'")
pcall(vim.api.nvim_buf_delete, plain, { force = true })

with_inline({ "Title", "{N=2}", "> A | B" }, function(buf)
  local win = vim.api.nvim_get_current_win()
  local st = inline.attach(buf)
  ok(st ~= nil, "attach creates a session")
  eq(inline.status(win), "text", "attaching does not change what the window shows")
  eq(vim.api.nvim_win_get_buf(win), buf, "the real text is on screen until asked otherwise")
  ok(
    vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("i", "n")
    end) == "",
    "the source buffer keeps its ordinary editing keys"
  )

  eq(inline.open(buf), "preview", "open reports the preview")
  local pbuf = vim.api.nvim_win_get_buf(win)
  ok(pbuf ~= buf, "the preview is a separate buffer")
  eq(inline.resolve(pbuf), buf, "the preview buffer resolves back to its source")
  eq(vim.bo[pbuf].buftype, "acwrite", "the preview buffer is writable by command")
  eq(vim.bo[pbuf].modifiable, false, "the preview buffer cannot be edited")
  eq(inline.status(win), "preview", "status reports the preview")
  eq(inline.is_preview(win), true, "is_preview agrees")
  lines_eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    { "Title", "{N=2}", "> A | B" },
    "the source buffer is left alone"
  )
  local shown = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
  lines_eq({ vim.trim(shown[1]), vim.trim(shown[2]) }, { "Title", "A B" }, "the preview shows the layout")

  local descs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    descs[m.desc or ""] = true
  end
  ok(descs["textlayout: swap between the preview and the text"], "the toggle key is mapped in NORMAL mode")
  eq(
    vim.api.nvim_buf_call(pbuf, function()
      return vim.fn.maparg("i", "n")
    end),
    "",
    "the preview buffer no longer remaps editing keys"
  )

  -- the cursor follows the line you were on, through every step
  inline.hide(win, buf)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  inline.show(win, buf)
  eq(vim.api.nvim_win_get_cursor(win)[1], 2, "source line 3 maps to preview line 2")

  eq(inline.toggle(buf), "split", "toggling from the preview opens the pane beside the text")
  eq(vim.api.nvim_win_get_buf(win), buf, "the window you were reading in gets the text back")
  eq(vim.api.nvim_win_get_cursor(win)[1], 3, "the cursor comes back to the source line")
  local twin, pwin = inline.split_windows(buf)
  eq(twin, win, "the text keeps the window you were in")
  ok(pwin ~= win and vim.api.nvim_win_is_valid(pwin), "the preview gets a window of its own")
  eq(vim.api.nvim_win_get_buf(pwin), pbuf, "the pane shows the preview buffer")
  eq(vim.api.nvim_win_get_cursor(pwin)[1], 2, "the pane opens on the line you were reading")
  ok(vim.api.nvim_win_get_width(pwin) < vim.api.nvim_win_get_width(win), "the pane leaves room for the text")
  eq(inline.arrangement(win), "split", "the document is arranged side by side")

  eq(inline.toggle(buf), "preview", "toggling again collapses back to the preview")
  eq(inline.status(win), "preview", "the preview fills the window again")
  eq(vim.api.nvim_win_get_buf(win), pbuf, "and it is the window you were in")
  eq(vim.api.nvim_win_get_cursor(win)[1], 2, "still on the same rendered line")
  eq(#vim.api.nvim_list_wins(), 1, "the pane beside it is gone")

  inline.show(win, buf)
  eq(inline.status(win), "preview", "show puts the preview up")
  eq(inline.close(buf), "text", "close reports the text")
  eq(vim.api.nvim_win_get_buf(win), buf, "close restores the real text")
  eq(inline.status(win), "text", "status reports the text")
  eq(vim.api.nvim_win_get_cursor(win)[1], 3, "close keeps the cursor on the same line")

  -- an open preview follows edits to the source
  inline.open(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Title", "", "A | B" })
  inline.sync(buf)
  shown = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
  ok(table.concat(shown, "\n"):find("A B", 1, true) ~= nil, "sync re-renders an open preview")
  eq(inline.close(buf), "text", "close leaves the text on screen again")
end)

do
  local tmp = vim.fn.tempname() .. ".tlmd"
  vim.fn.writefile({ "Alpha", "Beta | 1" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local fbuf = vim.api.nvim_get_current_buf()
  vim.bo[fbuf].filetype = "tlmd"
  local fwin = vim.api.nvim_get_current_win()
  local ok_ = pcall(function()
    inline.attach(fbuf)
    eq(inline.open(fbuf), "preview", "a file-backed buffer previews in place")
    ok(vim.api.nvim_win_get_buf(fwin) ~= fbuf, "the preview buffer is on screen")

    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "Alpha", "Beta | 1", "Gamma" })
    vim.cmd("write")
    eq(
      table.concat(vim.fn.readfile(tmp), "\n"),
      "Alpha\nBeta | 1\nGamma",
      ":w from the preview writes the real text, never the layout"
    )
    eq(vim.bo[fbuf].modified, false, "writing clears 'modified'")

    inline.close(fbuf)
    eq(vim.api.nvim_win_get_buf(fwin), fbuf, "closing shows the real text again")
  end)
  pcall(inline.detach, fbuf)
  pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
  vim.fn.delete(tmp)
  if not ok_ then
    fail("error while writing from the preview")
  end
end

-- A newly displayed .tlmd window shows the preview; a window you have toggled
-- to the text stays there.  Nothing swaps buffers on a mode change.
do
  local evs = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "textlayout-inline" })) do
    local events = type(a.event) == "table" and a.event or { a.event }
    for _, e in ipairs(events) do
      evs[e] = true
    end
  end
  ok(evs.BufWinEnter and evs.WinEnter and evs.FileType, "displaying a .tlmd buffer offers the preview")
  ok(evs.ModeChanged == nil and evs.InsertEnter == nil, "no mode change swaps buffers behind your back")

  local tmp = vim.fn.tempname() .. ".tlmd"
  vim.fn.writefile({ "Alpha", "Beta | 1" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local fbuf = vim.api.nvim_get_current_buf()
  vim.bo[fbuf].filetype = "tlmd"
  local win1 = vim.api.nvim_get_current_win()
  local ok_ = pcall(function()
    inline.attach(fbuf)
    eq(inline.status(win1), "text", "attaching alone leaves the text on screen")
    eq(inline.toggle(fbuf), "split", "the toggle puts the preview beside the text")
    eq(inline.toggle(fbuf), "preview", "and again for the preview on its own")
    eq(inline.toggle(fbuf), "split", "the toggle flips back to the side by side view")
    eq(inline.close(fbuf), "text", "close puts the plain text back")

    vim.cmd("split")
    vim.wait(50, function()
      return false
    end)
    local win2 = vim.api.nvim_get_current_win()
    eq(inline.status(win2), "preview", "a new window shows the preview")
    eq(inline.status(win1), "text", "the window you set to text stays on the text")

    vim.cmd("wincmd p")
    vim.wait(50, function()
      return false
    end)
    eq(inline.status(win1), "text", "coming back does not re-render a window you set to text")

    inline.resize_all()
    eq(inline.status(win2), "preview", "resize_all leaves an open preview alone")
    local widest = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win2), 0, -1, false)) do
      widest = math.max(widest, text.dwidth(line))
    end
    ok(widest <= vim.api.nvim_win_get_width(win2), "the preview still fits the window")
  end)
  vim.cmd("only")
  pcall(inline.detach, fbuf)
  pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
  vim.fn.delete(tmp)
  if not ok_ then
    fail("error while testing the display autocommands")
  end
end


----------------------------------------------------------------------
group("inline: a half-typed document stays quiet")
----------------------------------------------------------------------

-- The pane is re-rendered on every keystroke, so a document that is halfway
-- through being typed must never raise and must never pop anything up.
local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, ...)
  notified[#notified + 1] = tostring(msg)
  return real_notify(msg, ...)
end

local typing = {
  "Name | Bob\n[",
  "Name | Bob\n[a|b",
  "Name | Bob\n{",
  "Name | Bob\n{1+",
  "Name | Bob\n{NOPE}",
  "Name | Bob\n{X=}",
  "Name | Bob\n@grid [\na|b",
  "Name | Bob\n@row [a|b",
  "Name | Bob\n]",
  "Name | Bob",
}

with_inline({ "Name | Bob" }, function(buf)
  inline.attach(buf)
  inline.split(buf)
  eq(inline.arrangement(vim.api.nvim_get_current_win()), "split", "the pane is open beside the text")

  local was_error = inline.last_error()
  for _, text in ipairs(typing) do
    local before = #notified
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    local ok_, err = pcall(inline.sync, buf)
    ok(ok_, "sync survives " .. string.format("%q", text) .. ": " .. tostring(err))
    eq(#notified, before, "nothing is notified for " .. string.format("%q", text))
    local st = inline.session(buf)
    ok(st ~= nil and st.render_buf ~= nil, "the session survives " .. string.format("%q", text))
    if st and st.render_buf and vim.api.nvim_buf_is_valid(st.render_buf) then
      ok(
        #vim.api.nvim_buf_get_lines(st.render_buf, 0, -1, false) > 0,
        "the pane still has lines for " .. string.format("%q", text)
      )
    end
  end
  eq(inline.last_error(), was_error, "no callback raised while typing")

  -- broken meta says so where it was written
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Name | {NOPE}" })
  inline.sync(buf)
  local st = inline.session(buf)
  eq(
    vim.trim(vim.api.nvim_buf_get_lines(st.render_buf, 0, -1, false)[1]),
    "Name #UNDEF",
    "#UNDEF shows up in the pane"
  )
  ok(#inline.warnings(buf) > 0, "the warning is kept on the session, not shown")
end)

vim.notify = real_notify

----------------------------------------------------------------------
group("examples")
----------------------------------------------------------------------

local function read_example(name)
  local path = root .. "/examples/" .. name
  local lines = vim.fn.readfile(path)
  ok(#lines > 0, "example " .. name .. " exists")
  return table.concat(lines, "\n")
end

local sheet = textlayout.render(read_example("character-sheet.tl"), { width = 60 })
local sheet_text = table.concat(sheet.lines, "\n")
ok(sheet_text:find("Bob the Bold", 1, true) ~= nil, "example keeps literal prose")
eq(vim.trim(sheet.lines[1]), "Bob the Bold", "example does not start with a blank line")
ok(sheet_text:find("Name  Bob", 1, true) ~= nil, "example centres the cells of a table")
ok(sheet_text:find("Attack 4", 1, true) ~= nil, "example computes DEX+PROF")
ok(sheet_text:find("DEX  14 (2)", 1, true) ~= nil, "example computes the DEX modifier")
ok(sheet_text:find("HP 22", 1, true) ~= nil, "example computes HP inside a grid")
eq(#sheet.warnings, 0, "example renders without warnings")
for _, line in ipairs(sheet.lines) do
  ok(text.dwidth(line) <= 60, "example line fits the pane")
end

local dnd = textlayout.render(read_example("dnd-character-sheet.tl"), { width = 60 })
local dnd_text = table.concat(dnd.lines, "\n")
eq(#dnd.warnings, 0, "dnd sheet renders without warnings")
ok(dnd_text:find("Kaelen Stormward Cleric 5 (War Domain)", 1, true) ~= nil, "dnd sheet shows name and class")
ok(dnd_text:find(" AC 17   Initiative 1 Save DC 14", 1, true) ~= nil, "dnd sheet shows ac, initiative and save dc")
ok(dnd_text:find("  WIS    16    3   6    P", 1, true) ~= nil, "dnd sheet shows the ability grid")
ok(dnd_text:find("  CHA     8   -1   -1   -", 1, true) ~= nil, "dnd sheet handles a negative modifier")
ok(dnd_text:find("Mace      1d6+2 bludgeoning", 1, true) ~= nil, "dnd sheet computes weapon damage")
ok(dnd_text:find("1st (4)  Bless", 1, true) ~= nil, "dnd sheet lists spells")
ok(dnd_text:find("HP 38/38 Gold 245 gp", 1, true) ~= nil, "dnd sheet shows hp and gold")
for _, line in ipairs(dnd.lines) do
  ok(text.dwidth(line) <= 60, "dnd sheet line fits the pane")
end
ok(not dnd_text:find("saving throw training", 1, true), "the definition-only line renders nothing")

local dnd48 = textlayout.render(read_example("dnd-character-sheet.tl"), { width = 48 })
ok(dnd48.natural_width <= 48, "dnd sheet needs no shrinking in a 48 column pane")
for _, line in ipairs(dnd48.lines) do
  ok(not line:find("\226\128\166", 1, true), "dnd sheet is not truncated at 48 columns: " .. line)
end

local demo = textlayout.render(read_example("layout-demo.tl"), { width = 60 })
local demo_text = table.concat(demo.lines, "\n")
ok(demo_text:find("Left Middle Right", 1, true) ~= nil, "demo aligns a table")
ok(demo_text:find("one   two   three", 1, true) ~= nil, "demo centres table columns")
ok(demo_text:find("status is OK.", 1, true) ~= nil, "demo inlines a group")
ok(demo_text:find("alpha next to the stack", 1, true) ~= nil, "demo puts a stack beside text")
ok(demo_text:find("write @row to make it flow", 1, true) ~= nil, "demo shows the marker")
eq(
  vim.trim(demo.lines[#demo.lines - 1]) .. "\n" .. vim.trim(demo.lines[#demo.lines]),
  "Left Right\none   two",
  "demo flows a forced row layer and shares its column widths"
)
eq(#demo.warnings, 0, "demo renders without warnings")

----------------------------------------------------------------------
group("plugin")
----------------------------------------------------------------------

vim.cmd("source " .. root .. "/plugin/textlayout.lua")
eq(vim.fn.exists(":TextLayout"), 2, "TextLayout command is registered")
eq(vim.fn.exists(":TextLayoutExport"), 2, "TextLayoutExport command is registered")
eq(vim.fn.exists(":TextLayout") == 2 and vim.g.loaded_textlayout, 1, "plugin guard is set")


lines_eq(
  render_lines("{A=1}\n\n> {B=2}\n\n> Text"),
  { "Text" },
  "blank lines around dropped meta lines disappear with them"
)
lines_eq(
  render_lines("Hello\n\n> {A=1}\n\n> World"),
  { "Hello", "World" },
  "a dropped meta line takes its separators with it"
)
lines_eq(
  render_lines("Hello\n\n> World"),
  { "Hello", "", "World" },
  "blank lines between real content are kept"
)

----------------------------------------------------------------------
group("layout directives")
----------------------------------------------------------------------

lines_eq(
  render_lines("@gap(4)\n> @row [a | b\n>       c | d]"),
  { "a    b", "c    d" },
  "@gap widens the columns of the layer that follows"
)
lines_eq(
  render_lines("@gap(4) @cell_align(right)\n> @row [Name | Bob\n>       DEX  | 14]"),
  { "Name    Bob", " DEX     14" },
  "several directives on one line stack up"
)
lines_eq(
  render_lines("@gap(4)\n> @cell_align(right)\n> @row [Name | Bob\n>       DEX  | 14]"),
  { "Name    Bob", " DEX     14" },
  "and the same directives work one per line"
)
lines_eq(
  render_lines("@gap(4)\n> @row [a | b]\n\n> x | y"),
  { "a    b", "", "x y" },
  "a directive is scoped to its layer and does not leak"
)
lines_eq(
  render_lines("@align_columns(false)\n> @align(bottom)\n> @row [[a\n>        b] | X]"),
  { "a", "b X" },
  "@align(bottom) drops the shorter cell to the bottom"
)
lines_eq(
  render_lines("@gap(3)\n> @grid [\n> a|b\n> c|d\n]"),
  { "a   b", "c   d" },
  "a grid honours the directive too"
)
lines_eq(
  render_lines("@gap(4)\n> a | b\n> c | d"),
  { "a    b", "c    d" },
  "a directive can retune a bare row"
)

local dw = render.render("@gap(x)\n> a | b", {})
eq(#dw.warnings, 1, "a malformed directive warns")
eq(dw.lines[1], "@gap(x)", "and renders literally")

local nt = render.render("text\n> @gap(4)", {})
eq(#nt.warnings, 1, "a directive with no target warns")
lines_eq(nt.lines, { "text" }, "and adds no line")

lines_eq(render_lines("email me at a@b.com"), { "email me at a@b.com" }, "@ in ordinary text is literal")

-- @align takes the vertical alignment and, optionally, the horizontal one.
lines_eq(
  render_lines("@align(top, edges)\n> Left | Center | Right", { width = 20 }),
  { "Left   Center  Right" },
  "@align(v, edges) spreads a row out to the edges of the pane"
)
lines_eq(
  render_lines("Left | Center | Right", { width = 20, justify = "edges" }),
  { "Left   Center  Right" },
  "edges works as a plain option too"
)
lines_eq(
  render_lines("Left | Center | Right", { width = 20, justify = "right" }),
  { "   Left Center Right" },
  "justify = right pushes a row to the right"
)
lines_eq(
  render_lines("Left | Center | Right", { width = 20, justify = "center" }),
  { " Left Center Right" },
  "justify = center keeps a lone row centred"
)
lines_eq(
  render_lines("Left | Center | Right", { justify = "edges" }),
  { "Left Center Right" },
  "edges does nothing when there is no spare width"
)
lines_eq(
  render_lines("@align(, edges)\n> a | b", { width = 20 }),
  { "a                  b" },
  "@align can set only the horizontal axis"
)
lines_eq(
  render_lines("@align(edges)\n> a | b", { width = 20 }),
  { "a                  b" },
  "a lone horizontal value works too"
)
lines_eq(
  render_lines("@align(top, edges)\n> Name | Bob\n> DEX | 14", { width = 20 }),
  { "Name             Bob", "DEX              14" },
  "@align spreads a table run too"
)
lines_eq(
  render_lines("@align(top, edges)\n> @grid [\n> a|b|c\n]", { width = 20 }),
  { "a         b        c" },
  "a grid honours @align too"
)
lines_eq(
  render_lines("@align_columns(false)\n> @align(bottom, edges)\n> @row [[a\n>        b] | X]", { width = 6 }),
  { "a", "b    X" },
  "@align(bottom, edges) drops the shorter cell and spreads the row"
)

-- @align's two axes.  The vertical one aligns the shorter cell inside a grid
-- row, and the horizontal one places the whole block in the width it was
-- given -- a row, a group, or a document made of prose.
lines_eq(
  render_lines("@align(top)\n> @grid [\n> [a\n> b] | X\n]"),
  { "a X", "b" },
  "@align(top) keeps the shorter cell at the top of a grid row"
)
lines_eq(
  render_lines("@align(center)\n> @grid [\n> [a\n> b\n> c] | X\n]"),
  { "a", "b X", "c" },
  "@align(center) centres the shorter cell in a grid row"
)
lines_eq(
  render_lines("@align(bottom)\n> @grid [\n> [a\n> b\n> c] | X\n]"),
  { "a", "b", "c X" },
  "@align(bottom) drops the shorter cell to the bottom of a grid row"
)
lines_eq(
  render_lines("@align(, left)\nhello", { width = 20 }),
  { "hello" },
  "@align(, left) packs a prose document against the left edge"
)
lines_eq(
  render_lines("@align(, center)\nhello", { width = 20 }),
  { "       hello" },
  "@align(, center) centres a prose document"
)
lines_eq(
  render_lines("@align(, right)\nhello", { width = 20 }),
  { "               hello" },
  "@align(, right) pushes a prose document to the right"
)
lines_eq(
  render_lines("@align(, right)\nhello\n> world", { width = 20 }),
  { "               hello", "               world" },
  "a directive in front of prose configures the whole flow"
)
lines_eq(
  render_lines("hello", { width = 20 }),
  { "       hello" },
  "without @align a prose document is still centred"
)
lines_eq(
  render_lines("@align(, left)\na | b", { width = 20 }),
  { "a b" },
  "@align(, left) packs a row against the left edge"
)
local aw = render.render("@align(sideways)\n> a | b", {})
eq(#aw.warnings, 1, "a malformed @align warns")
eq(aw.lines[1], "@align(sideways)", "and renders literally")

-- `-----` draws a rule, with box characters by default; `rules = "ascii"`
-- keeps the dashes and pipes that were written.
lines_eq(
  render_lines("Abilities\n> -----\n> some much longer line here", { rules = "unicode" }),
  { "Abilities", string.rep("─", 26), "some much longer line here" },
  "a rule fills the width it is drawn across"
)
lines_eq(
  render_lines("a | -----\n> b | -----", { rules = "unicode" }),
  { "a │", "b │" },
  "a rule standing in a row is a vertical divider"
)
lines_eq(
  render_lines("a | -----\n> -----\n> b | -----", { rules = "unicode" }),
  { "a │", "──┤", "b │" },
  "a rule joins up with the dividers it runs into"
)
lines_eq(
  render_lines("Abilities\n> -----\n> some much longer line here", {}),
  { "Abilities", string.rep("─", 26), "some much longer line here" },
  "the default style draws rules with box characters"
)
lines_eq(
  render_lines("Abilities\n> -----\n> some much longer line here", { rules = "ascii" }),
  { "Abilities", string.rep("-", 26), "some much longer line here" },
  "the ascii style keeps the dashes that were written"
)
lines_eq(
  render_lines("Abilities\n> -----\n> longer line here", { rules = "nope" }),
  { "Abilities", string.rep("─", 16), "longer line here" },
  "an unknown rule style falls back to the default"
)

lines_eq(
  render_lines("@align(, center)\n[Title\n> -----\n> textx]", { width = 40 }),
  { "                 Title", "                 ─────", "                 textx" },
  "a rule keeps the width of its group, not the pane, when @align pads the block"
)

-- A line whose only content is directives is not content either: it is as if
-- it had never been written, so it never becomes a blank row of its own.
lines_eq(render_lines("a\n@align(center)\nb"), { "a b" }, "a directive-only line is not a row")
lines_eq(render_lines("a\n@align(center)"), { "a" }, "not even at the end of the document")
lines_eq(render_lines("a\n> @gap(2)"), { "a" }, "nor after a break character")
lines_eq(
  render_lines("a\n\n> @align(center)\n\n> b"),
  { "a", "", "", "b" },
  "and the blank lines around it are still blank lines"
)
lines_eq(
  render_lines("@row\n@cell_align(right)\n[a | b]"),
  { "a b" },
  "@row reaches its layer across the directives in between"
)
lines_eq(
  render_lines("@gap(4)\n@cell_align(right)\n@row [Name | Bob\n> DEX  | 14]"),
  { "Name    Bob", " DEX     14" },
  "and every directive on the way still applies"
)
----------------------------------------------------------------------
group("sessions: a preview is not a document")
----------------------------------------------------------------------

local session = require("textlayout.session")
local preview = require("textlayout.preview")

-- A session is loaded by an editor that has the plugin on 'runtimepath', where
-- filetype detection knows the plugin's own extensions.  The suite reaches the
-- modules through package.path instead, so bring that detection in by hand and
-- install the autocommands a real session load fires.
vim.opt.rtp:prepend(root)
vim.cmd("runtime! ftdetect/*.lua")
session.setup()
local watched = {}
for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "textlayout-session" })) do
  watched[au.event] = true
end
ok(watched.SessionLoadPre and watched.SessionLoadPost, "a session load is watched on both sides")

local session_dir = vim.fn.tempname()
vim.fn.mkdir(session_dir, "p")

local function session_doc(name, lines)
  local path = session_dir .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

-- A preview buffer is recognised by its name; a document is not.
vim.cmd("enew")
local plain = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(plain, session.scheme .. "/tmp/not-a-document.tlmd")
eq(session.source_of(plain), "/tmp/not-a-document.tlmd", "a preview knows the document it belongs to")
eq(session.source_of(vim.api.nvim_create_buf(false, true)), nil, "an unnamed buffer is not a preview")
pcall(vim.api.nvim_buf_delete, plain, { force = true })

-- A session that was saved with the layout on screen opens with it.
local doc = session_doc("sheet.tlmd", { "Name | Bob", "> DEX | 14" })
-- SessionLoadPre holds in-place rendering off while a session is read.
inline.begin_session_load()
vim.cmd("enew")
local doc_win = vim.api.nvim_get_current_win()
local artifact = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(artifact, session.scheme .. doc)
eq(session.restore(), 1, "the window a session restored with a preview in it is repaired")
eq(inline.arrangement(doc_win), "preview", "and it is showing the layout again")
ok(not vim.api.nvim_buf_is_valid(artifact), "the buffer the session restored is gone")
local doc_src = vim.fn.bufnr(doc)
ok(doc_src ~= -1 and vim.api.nvim_buf_is_valid(doc_src), "the real document is loaded")
eq(session.source_of(vim.api.nvim_win_get_buf(doc_win)), doc, "and the layout is named after it")
vim.api.nvim_set_current_win(doc_win)
inline.close(doc_src)
eq(inline.status(doc_win), "text", "closing the layout gives the text back")
lines_eq(
  vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(doc_win), 0, -1, false),
  { "Name | Bob", "> DEX | 14" },
  "and the text is exactly as it was written"
)
inline.detach(doc_src)

-- The text and the layout were both open: both come back.
vim.cmd("only")
-- Exactly what a session load looks like: in-place rendering holds off while
-- the windows are put back.
inline.begin_session_load()
vim.cmd("edit " .. vim.fn.fnameescape(doc))
local text_win = vim.api.nvim_get_current_win()
local split_src = vim.fn.bufnr(doc)
vim.cmd("vsplit")
vim.cmd("enew")
local artifact2 = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(artifact2, session.scheme .. doc)
local pane_win = vim.api.nvim_get_current_win()
eq(session.restore(), 1, "the layout window a session restored is repaired")
eq(inline.arrangement(pane_win), "split", "and the two windows are tied together again")
local tw, pw = inline.split_windows(split_src)
eq(tw, text_win, "the text window is the one the session put the text in")
eq(pw, pane_win, "and the layout is in the other one")
eq(vim.api.nvim_win_get_buf(text_win), split_src, "the text is not swapped away")
inline.detach(split_src)
vim.cmd("only")
inline.begin_session_load()

-- A document that is not rendered in place gets its pane back too.
local plain_doc = session_doc("sheet.tl", { "a | b" })
textlayout.setup({ preview = { mode = "split" } })
vim.cmd("edit " .. vim.fn.fnameescape(plain_doc))
local plain_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
vim.cmd("enew")
local artifact3 = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(artifact3, session.scheme .. plain_doc)
local pane3 = vim.api.nvim_get_current_win()
eq(session.restore(), 1, "a preview pane is repaired too")
local plain_src = vim.fn.bufnr(plain_doc)
ok(preview.is_open(plain_src), "the preview is open again")
eq(vim.api.nvim_win_get_buf(pane3), preview.buf_for(plain_src), "in the window the session used for it")
eq(vim.api.nvim_win_get_buf(plain_win), plain_src, "and the text window still shows the text")
preview.close(plain_src)
textlayout.setup({})
vim.cmd("only")

-- End to end: save a session with the layout on screen, load it in a fresh
-- Neovim, and see what the window shows.
local e2e_doc = session_doc("e2e.tlmd", { "Name | Bob", "> DEX | 14" })
local e2e_session = session_dir .. "/e2e.vim"
local e2e_out = session_dir .. "/e2e.out"
local e2e_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local make = session_dir .. "/make.lua"
vim.fn.writefile({
  'vim.cmd("edit " .. vim.fn.fnameescape([[' .. e2e_doc .. ']]))',
  'local inline = require("textlayout.inline")',
  "inline.attach(0)",
  "inline.open(0)",
  'vim.cmd("mksession! " .. vim.fn.fnameescape([[' .. e2e_session .. ']]))',
  'vim.cmd("qa!")',
}, make)

local check = session_dir .. "/check.lua"
vim.fn.writefile({
  'local inline = require("textlayout.inline")',
  "local win = vim.api.nvim_get_current_win()",
  "local out = { inline.arrangement(win), inline.status(win) }",
  'out[#out + 1] = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "|")',
  'vim.fn.writefile(out, [[' .. e2e_out .. ']])',
}, check)

local function headless(args)
  local cmd = { vim.v.progpath, "--headless", "-u", "NORC", "--cmd", "set rtp+=" .. e2e_root }
  vim.list_extend(cmd, args)
  return vim.fn.system(cmd)
end

if vim.fn.executable(vim.v.progpath) == 1 then
  headless({ "-l", make })
  headless({ "-S", e2e_session, "-c", "luafile " .. check, "-c", "qa!" })
  local loaded = vim.fn.readfile(e2e_out)
  eq(loaded[1], "preview", "a session saved with the layout on screen opens with it")
  eq(loaded[2], "preview", "and the window is showing the layout")
  ok(loaded[3] ~= nil and loaded[3]:find("Name Bob", 1, true) ~= nil, "and it is the document's layout")
end

----------------------------------------------------------------------
group("overflow modes")
----------------------------------------------------------------------

local prose = "the quick brown fox jumps over the lazy dog"

lines_eq(render_lines(prose, { width = 12 }), { "the quick b…" }, "prose is truncated by default")

local wrapped = render_lines(prose, { width = 12, overflow = "wrap" })
ok(#wrapped > 1, "wrap produces several lines")
for _, line in ipairs(wrapped) do
  ok(text.dwidth(line) <= 12, "wrapped line fits: " .. line)
end
eq(wrapped[1], "the quick", "wrap breaks on words")
eq(table.concat(wrapped, " "), prose, "wrap loses no words")

local long_word = render_lines("supercalifragilistic", { width = 6, overflow = "wrap" })
eq(#long_word, 4, "an over-long word is hard-broken")
eq(table.concat(long_word), "supercalifragilistic", "hard break loses nothing")

eq(text.wrap("a b c", 10)[1], "a b c", "wrap leaves short text alone")

io.write("\n")
if failed == 0 then
  io.write(string.format("ok - %d assertions passed\n", passed))
  vim.cmd("qa!")
else
  io.write(string.format("%d passed, %d FAILED\n", passed, failed))
  for _, f in ipairs(failures) do
    io.write("  - " .. f .. "\n")
  end
  vim.cmd("cq")
end
