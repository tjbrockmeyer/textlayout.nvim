-- lua/textlayout/render.lua
-- Source text -> lines that fit in a pane.

local meta = require("textlayout.meta")
local parser = require("textlayout.parser")
local layout = require("textlayout.layout")
local text = require("textlayout.text")

local M = {}

--- A line that was nothing but meta and evaluated to nothing (a pure
-- `{X=1}` assignment line) is dropped instead of becoming a blank line.
local function is_droppable(node, opts)
  if opts.drop_empty_meta_lines == false then
    return false
  end
  return node.type == "text" and node.was_meta == true and node.value == ""
end

--- Walk the AST in document order, evaluating `{ ... }` groups.  Assignments
-- mutate `env`, so order matters: `{X=1}` must be evaluated before `{X}`.
local function eval_ast(node, env, warnings, opts)
  if node.type == "text" then
    local out = {}
    local was_meta = false
    for _, part in ipairs(node.parts or {}) do
      if part.kind == "text" then
        out[#out + 1] = part.value
      else
        was_meta = true
        local value, err = meta.eval(part.value, env)
        if err then
          -- A group that failed to evaluate is a *known* kind of problem, so
          -- it shows up as a marker where it was written.  Anything the parser
          -- could not even recognise stays literal text instead.
          warnings[#warnings + 1] = "{" .. part.value .. "}: " .. err
          out[#out + 1] = opts.undef or "#UNDEF"
        else
          out[#out + 1] = meta.fmt(value)
        end
      end
    end
    return {
      type = "text",
      value = table.concat(out),
      was_meta = was_meta,
      line = node.line,
    }
  end

  if node.type == "box" or node.type == "grid" then
    local is_column = node.type == "box" and node.dir == "col"
    local entries = {}
    for _, child in ipairs(node.children) do
      local evaluated = eval_ast(child, env, warnings, opts)
      entries[#entries + 1] = {
        node = evaluated,
        dropped = is_column and is_droppable(evaluated, opts),
      }
    end

    local children = {}
    for i, entry in ipairs(entries) do
      if not entry.dropped then
        -- A blank line that only existed to separate `{X=1}` lines goes away
        -- with them, so a block of definitions disappears cleanly.
        local blank = entry.node.type == "text" and entry.node.value:match("^%s*$") ~= nil
        local orphaned = blank
          and (
            (entries[i - 1] ~= nil and entries[i - 1].dropped)
            or (entries[i + 1] ~= nil and entries[i + 1].dropped)
          )
        if not orphaned then
          children[#children + 1] = entry.node
        end
      end
    end
    -- Whitespace at the edge of a container is a separator in the source, not
    -- content: only whitespace *between* two pieces of text is rendered.  This
    -- is what stops a `{X=1}` group that evaluates to nothing from leaving its
    -- neighbours' padding behind.
    local first = children[1]
    if first and first.type == "text" then
      local value = string.gsub(first.value, "^%s+", "")
      if value ~= first.value then
        children[1] = { type = "text", value = value, was_meta = first.was_meta, line = first.line }
      end
    end
    local last = children[#children]
    if last and last.type == "text" then
      local value = string.gsub(last.value, "%s+$", "")
      if value ~= last.value then
        children[#children] = { type = "text", value = value, was_meta = last.was_meta, line = last.line }
      end
    end

    local out =
      { type = node.type, gap = node.gap, line = node.line, children = children, opts = node.opts }
    if node.type == "box" then
      out.dir = node.dir
      out.align = node.align
      out.table = node.table
    else
      out.rows = node.rows
      out.cols = node.cols
    end
    return out
  end

  return node
end

M.eval_ast = eval_ast

--- Render `source`.
--
-- opts:
--   width                pane width in columns (nil = natural width)
--   env                  environment table (see meta.new_env)
--   gap                  columns between `|`-separated cells (default 1)
--   align                "top" | "center" | "bottom"
--   cell_align           "left" | "center" | "right" inside a column
--   ellipsis             truncation marker
--   undef                what a `{ ... }` that failed to evaluate shows as
--   symbols              symbol overrides
--   drop_empty_meta_lines  remove `{X=1}`-only lines (default true)
--
-- @return { lines, warnings, width, natural_width, height, env, line_map }
function M.render(source, opts)
  opts = opts or {}
  local warnings = {}
  local ast, parse_warnings = parser.parse(source, opts)
  for _, w in ipairs(parse_warnings) do
    warnings[#warnings + 1] = w
  end

  local env = opts.env or meta.new_env(opts.base_env)
  local evaluated = eval_ast(ast, env, warnings, opts)

  -- Blank lines are preserved inside the document, but a preview that starts
  -- (or ends) with empty rows is just wasted pane space.
  if opts.trim_blank_edges ~= false and evaluated.type == "box" and evaluated.dir == "col" then
    local function is_blank(node)
      return node.type == "text" and node.value:match("^%s*$") ~= nil
    end
    while #evaluated.children > 0 and is_blank(evaluated.children[1]) do
      table.remove(evaluated.children, 1)
    end
    while #evaluated.children > 0 and is_blank(evaluated.children[#evaluated.children]) do
      table.remove(evaluated.children)
    end
  end

  local natural_width = layout.measure(evaluated, opts)
  local block = layout.layout(evaluated, opts.width, opts)
  local width = opts.width

  local lines = {}
  if width and block.w < width then
    local left = math.floor((width - block.w) / 2)
    local pad = string.rep(" ", left)
    for i, line in ipairs(block.lines) do
      lines[i] = text.pad_right(pad .. line, width)
    end
  else
    for i, line in ipairs(block.lines) do
      if width then
        lines[i] = text.pad_right(text.clip(line, width), width)
      else
        lines[i] = line
      end
    end
  end

  -- Trailing padding is invisible but noisy (and trips up whitespace
  -- highlighters), so it never leaves the renderer.
  if opts.trim_output ~= false then
    for i = 1, #lines do
      lines[i] = string.gsub(lines[i], "%s+$", "")
    end
  end

  return {
    lines = lines,
    warnings = warnings,
    width = block.w,
    natural_width = natural_width,
    height = #lines,
    env = env,
    -- line_map[i] is the 1-based source line that produced rendered line i
    -- (0 = synthetic: padding, or a shrunk grid cell with no source).
    line_map = block.src or {},
  }
end

--- Render `source` and return the lines only.
function M.lines(source, opts)
  return M.render(source, opts).lines
end

--- Render `source` at its natural width (nothing shrunk, nothing centred).
function M.natural(source, opts)
  local o = {}
  for k, v in pairs(opts or {}) do
    o[k] = v
  end
  o.width = nil
  return M.render(source, o)
end

return M
