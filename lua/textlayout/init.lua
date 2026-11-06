-- lua/textlayout/init.lua
-- Public API for the textlayout plugin.

local util = require("textlayout.util")
local parser = require("textlayout.parser")
local render = require("textlayout.render")
local meta = require("textlayout.meta")

local M = {}

M.version = "0.1.0"

M.defaults = {
  -- Pane width in columns. nil means "use the preview pane width".
  width = nil,
  -- Columns inserted between `|`-separated cells and between grid columns.
  gap = 1,
  -- Vertical alignment of shorter cells inside a row: top | center | bottom.
  align = "top",
  -- Horizontal placement of a cell inside its column: left | center | right.
  -- `|` cells and grid cells line up on the columns either way; this only
  -- decides where the text sits inside the column it was given.
  cell_align = "center",
  -- Consecutive `|` rows share column widths so they line up like a table.
  align_columns = true,
  -- How the spare width of a row or grid is shared out between its cells, and
  -- where a whole stack sits in the width it was given: nil leaves it to the
  -- renderer, which centres the document | "left" | "center" | "right" |
  -- "edges" (spread out to the edges, like CSS space-between).
  justify = nil,
  -- How a `-----` rule is drawn: "unicode" draws it with box-drawing
  -- characters and joins the crossings up, "ascii" keeps the dashes and
  -- pipes you wrote.
  rules = "unicode",
  -- Character used when a cell has to be cut down to fit.
  ellipsis = "\226\128\166",
  -- What a `{ ... }` group that could not be evaluated renders as.  Broken
  -- syntax that the parser cannot identify is rendered as written instead.
  undef = "#UNDEF",
  -- What to do with a text cell that is wider than its column:
  -- "truncate" (default) or "wrap".
  overflow = "truncate",
  -- Source tidying.
  dedent = true,
  trim_trailing = true,
  -- A line that is nothing but meta and evaluates to nothing (a bare
  -- `{X=1}`) is dropped instead of becoming a blank line.
  drop_empty_meta_lines = true,
  -- Blank lines are kept inside a document but trimmed from its start/end.
  trim_blank_edges = true,
  tabstop = 4,
  -- Symbol overrides.
  symbols = {},
  -- Base environment; `{X=1}` inside a document shadows these.
  env = {},
  preview = {
    mode = "float", -- float | split
    width = nil, -- nil = 60% of the editor width
    border = "rounded",
    title = " textlayout ",
    close_keys = { "q", "<Esc>" },
    -- Move the cursor into the pane when it opens (also settable per call
    -- with require("textlayout.preview").open(bufnr, { enter = true })).
    enter = false,
    refresh_on = { "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost" },
    debounce = 80,
  },
  filetypes = { "textlayout" },
  -- In-place rendering: a `.tlmd` buffer is shown laid out in its own window
  -- and swapped back to the real text with a keybinding, keeping the cursor on
  -- the same line; see lua/textlayout/inline.lua.
  inline = {
    enabled = true,
    -- Filetypes that render in place.
    filetypes = { "tlmd" },
    -- NORMAL-mode key that swaps the preview and the text in the current
    -- window.  Set to false to bind nothing.
    toggle_key = "<leader>tp",
    -- Pane width for the in-place preview; nil = the width of the window.
    width = nil,
    -- Width of the preview pane when it is split beside the text; nil = as
    -- wide as the layout needs, leaving at least 20 columns of text.
    split_width = nil,
    -- Which side that pane opens on: "right" (default) or "left".
    split_side = "right",
    -- Filetype given to the scratch buffer that holds the rendered lines.
    render_filetype = "textlayout",
  },
}

local config = util.deepcopy(M.defaults)

--- Apply user configuration.
function M.setup(opts)
  config = util.merge(M.defaults, opts or {})
  return config
end

--- Current effective configuration.
function M.get_config()
  return config
end

--- Replace the current configuration wholesale (mainly for tests).
function M.set_config(opts)
  config = util.merge(M.defaults, opts or {})
  return config
end

--- Render `source` to lines that fit `opts.width`.
function M.render(source, opts)
  local o = util.merge(config, opts or {})
  return render.render(source, o)
end

--- Render `source` at its natural width.
function M.render_natural(source, opts)
  local o = util.merge(config, opts or {})
  o.width = nil
  return render.render(source, o)
end

--- Read `path` and render it.
function M.render_file(path, opts)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return { lines = {}, warnings = { "cannot read " .. path }, width = 0, height = 0 }
  end
  return M.render(table.concat(lines, "\n"), opts)
end

--- Render the lines of a buffer.
function M.render_buffer(bufnr, opts)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.render(table.concat(lines, "\n"), opts)
end

M.parser = parser
M.renderer = render
M.meta = meta

return M
