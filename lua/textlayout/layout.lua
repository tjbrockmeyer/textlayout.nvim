-- lua/textlayout/layout.lua
-- Measures and arranges an evaluated AST into a rectangular block of lines.
--
-- A "block" is { w = display_width, h = line_count, lines = { string, ... } }
-- where every line is padded to exactly `w` display columns. Blocks are built
-- bottom-up; `avail` is the number of columns the parent can afford, and is
-- `nil` when measuring at natural size.

local text = require("textlayout.text")
local util = require("textlayout.util")

local M = {}

--- UTF-8 for a box-drawing character (they all live in U+2500..U+253F),
-- written as bytes so the source stays plain ASCII.
local function box(byte)
  return string.char(0xE2, 0x94, byte)
end

--- How a `-----` rule is drawn.  `ascii` keeps the dashes and pipes exactly as
-- they were written; `unicode` draws them with box-drawing characters and,
-- with `join`, ties the crossings together so a rule that runs into a divider
-- reads as one connected shape.
local rule_styles = {
  ascii = { h = "-", v = "|" },
  unicode = {
    h = box(0x80), -- horizontal
    v = box(0x82), -- vertical
    join = true,
    cross = box(0xBC),
    down = box(0xAC),
    up = box(0xB4),
    right = box(0x9C),
    left = box(0xA4),
    corner_dr = box(0x8C),
    corner_dl = box(0x90),
    corner_ur = box(0x94),
    corner_ul = box(0x98),
  },
}

--- The rule characters for a render; `opts.rules` names the style.
local function rule_chars(opts)
  return rule_styles[opts and opts.rules] or rule_styles.unicode
end

--- Tie a horizontal rule into the vertical ones it runs into, so the two read
-- as a single shape: a cross where the divider carries on through, a tee where
-- it only reaches from one side, a corner where the rule stops.  Lines are
-- walked in display columns so wide characters stay lined up.
local function join_rules(lines, chars)
  local cols = {}
  for i = 1, #lines do
    local map, x = {}, 0
    for _, ch in ipairs(text.chars(lines[i])) do
      map[x] = ch
      x = x + text.dwidth(ch)
    end
    cols[i] = map
  end
  for i = 1, #lines do
    local map = cols[i]
    local above, below = cols[i - 1], cols[i + 1]
    local out, x, changed = {}, 0, false
    for _, ch in ipairs(text.chars(lines[i])) do
      local w = text.dwidth(ch)
      local rep = ch
      if ch == chars.h then
        local up = above and above[x] == chars.v
        local down = below and below[x] == chars.v
        local left = map[x - 1] == chars.h
        local right = map[x + 1] == chars.h
        if up and down then
          rep = (left and right) and chars.cross or (right and chars.right or chars.left)
        elseif up then
          rep = (left and right) and chars.up or (right and chars.corner_ur or chars.corner_ul)
        elseif down then
          rep = (left and right) and chars.down or (right and chars.corner_dr or chars.corner_dl)
        end
        if rep ~= ch then
          changed = true
        end
      end
      out[#out + 1] = rep
      x = x + w
    end
    if changed then
      lines[i] = table.concat(out)
    end
  end
end

--- Merge a node's own layout directives over the inherited options.  A
-- directive on a group is inherited by everything inside it, so this is what
-- makes `@gap(4)` before a `[...]` reach the rows it contains.
local function merged_opts(opts, node)
  if not node or not node.opts then
    return opts or {}
  end
  local o = {}
  if opts then
    for k, v in pairs(opts) do
      o[k] = v
    end
  end
  for k, v in pairs(node.opts) do
    o[k] = v
  end
  return o
end

--- Natural width of a node, ignoring any constraint.
local function measure(node, opts)
  if not node then
    return 0
  end
  if node.type == "text" then
    return text.dwidth(node.value or "")
  end
  if node.type == "rule" then
    -- A rule has no size of its own: it takes whatever the rest of its
    -- container already needs, so it never makes the document wider.
    return 0
  end
  local o = merged_opts(opts, node)
  if node.type == "box" then
    local total = 0
    if node.dir == "col" then
      -- A column of nothing but rules is as wide as the dashes written;
      -- otherwise the rules just fill the width the other items asked for.
      local rules, other = 0, false
      for _, child in ipairs(node.children) do
        if child.type == "rule" then
          rules = math.max(rules, child.dashes or 0)
        else
          other = true
          total = math.max(total, measure(child, o))
        end
      end
      if not other and rules > total then
        total = rules
      end
    else
      local gap = node.table and (o.gap or 1) or 0
      for i, child in ipairs(node.children) do
        if i > 1 then
          total = total + gap
        end
        total = total + measure(child, o)
      end
    end
    return total
  end
  if node.type == "grid" then
    local cols = node.cols or 0
    if cols == 0 then
      return 0
    end
    local gap = o.gap or 1
    local colw = {}
    for i, child in ipairs(node.children) do
      local c = ((i - 1) % cols) + 1
      colw[c] = math.max(colw[c] or 0, measure(child, o))
    end
    local total = 0
    for c = 1, cols do
      if c > 1 then
        total = total + gap
      end
      total = total + (colw[c] or 0)
    end
    return total
  end
  return 0
end

M.measure = measure

--- Split `budget` columns between items. When the natural widths do not fit,
-- the widest column gives up space first, so a narrow label column is never
-- squeezed just because a neighbouring column is very wide.
local function distribute(nats, budget)
  local count = #nats
  if count == 0 then
    return {}
  end
  local out, floors = {}, {}
  local used = 0
  for i, n in ipairs(nats) do
    floors[i] = n > 0 and 1 or 0
    out[i] = math.max(floors[i], n)
    used = used + out[i]
  end
  if used <= budget then
    return nats
  end

  while used > budget do
    local best = nil
    for i, w in ipairs(out) do
      if w > floors[i] and (best == nil or w > out[best]) then
        best = i
      end
    end
    if best == nil then
      break
    end
    out[best] = out[best] - 1
    used = used - 1
  end
  return out
end

M.distribute = distribute

--- Pad a block out to `w` columns (only ever grows it).
local function fit_width(block, w)
  if w <= block.w then
    return block
  end
  for i = 1, #block.lines do
    block.lines[i] = text.pad_right(block.lines[i], w)
  end
  block.w = w
  return block
end

--- Drop the padding `fit_width` added, so a cell can be re-placed.
local function strip_trailing(s)
  return (s or ""):gsub("%s+$", "")
end

--- Put `s` inside `w` display columns according to a horizontal alignment.
local function place(s, w, align)
  s = strip_trailing(s)
  if align == "right" then
    return text.pad_left(s, w)
  elseif align == "center" then
    return text.center(s, w)
  end
  return text.pad_right(s, w)
end

--- Work out how a row or grid of `k` items shares `free` spare columns
-- under a `justify` mode.  Returns the left padding and, for `edges`, a
-- per-gap list (nil means "use the plain gap between every pair").
local function justify_row(mode, k, free, gap)
  if free <= 0 or mode == nil or mode == "left" or k == 0 then
    return 0, nil
  end
  if mode == "center" then
    return math.floor(free / 2), nil
  elseif mode == "right" then
    return free, nil
  elseif mode == "edges" then
    if k < 2 then
      return 0, nil
    end
    local slots = k - 1
    local q, r = math.floor(free / slots), free % slots
    local gaps = {}
    for s = 1, slots do
      gaps[s] = gap + q + (s <= r and 1 or 0)
    end
    return 0, gaps
  end
  return 0, nil
end

local function vertical_offset(align, height, own)
  if align == "center" then
    return math.floor((height - own) / 2)
  elseif align == "bottom" then
    return height - own
  end
  return 0
end

local function empty_block()
  return { w = 0, h = 1, lines = { "" }, src = { 0 } }
end

local layout

local function layout_text(node, avail, opts)
  local s = node.value or ""
  local w = text.dwidth(s)
  local line = node.line or 0
  if avail and w > avail then
    if opts.overflow == "wrap" then
      local wrapped = text.wrap(s, avail)
      local widest = 0
      for i = 1, #wrapped do
        local lw = text.dwidth(wrapped[i])
        if lw > widest then
          widest = lw
        end
      end
      local src = {}
      for i = 1, #wrapped do
        src[i] = line
      end
      return { w = widest, h = #wrapped, lines = wrapped, src = src }
    end
    s = text.truncate(s, avail, opts.ellipsis)
    w = text.dwidth(s)
  end
  return { w = w, h = 1, lines = { s }, src = { line } }
end

local layout_grid

local function is_table_row(child)
  return child.type == "box" and child.dir == "row" and child.table == true
end

--- Consecutive `|` rows are laid out together so their columns line up.
-- This is what makes
--     Name | Bob
--     DEX  | 14
-- line up without having to reach for a grid.
local function layout_table_run(run, avail, opts)
  local cols = 0
  for _, row in ipairs(run) do
    if #row.children > cols then
      cols = #row.children
    end
  end
  if cols == 0 then
    return empty_block()
  end
  -- a directive on any row of the run sets the options for the whole table
  local run_opts = opts
  for _, row in ipairs(run) do
    run_opts = merged_opts(run_opts, row)
  end
  local cells = {}
  for r, row in ipairs(run) do
    for c = 1, cols do
      cells[(r - 1) * cols + c] = row.children[c]
    end
  end
  return layout_grid({
    type = "grid",
    -- a bare `|` row keeps the old block-level justify; only a real `@grid`
    -- hands the horizontal `@align` over to the cells
    from_rows = true,
    rows = #run,
    cols = cols,
    gap = run_opts.gap or 1,
    children = cells,
  }, avail, run_opts)
end

--- A rule that stands in a column draws across that column: it fills the
-- width the other items already asked for, and no more.
local function size_col_rule(block, w, chars)
  local target = w
  if target <= 0 then
    -- nothing else to measure against, so keep the dashes that were written
    target = block.rule.dashes or 1
  end
  block.lines = { string.rep(chars.h, target) }
  block.w = target
  return target
end

--- A rule that stands in a row is a divider: it spans the row and takes one
-- column of its own.
local function size_row_rule(block, h, chars)
  local lines = {}
  for r = 1, h do
    lines[r] = chars.v
  end
  block.lines = lines
  block.h = h
  block.w = 1
  return block
end

local function layout_col(node, avail, opts)
  local chars = rule_chars(opts)
  local blocks = {}
  local w, h = 0, 0
  local children = node.children
  local i = 1
  while i <= #children do
    local b
    if opts.align_columns ~= false and is_table_row(children[i]) then
      local run = {}
      while i <= #children and is_table_row(children[i]) do
        run[#run + 1] = children[i]
        i = i + 1
      end
      b = layout_table_run(run, avail, opts)
    else
      b = layout(children[i], avail, opts)
      i = i + 1
    end
    blocks[#blocks + 1] = b
    if b.w > w then
      w = b.w
    end
    h = h + b.h
  end
  -- Rules are sized last, once the column knows how wide it turned out.  A
  -- rule spans the width the other items asked for naturally -- not the width
  -- a `justify` padded them out to -- and never more than the column was
  -- given, so it always stays the width of its own group.
  local nat = 0
  for k = 1, #blocks do
    local bw = blocks[k].natural or blocks[k].w
    if bw > nat then
      nat = bw
    end
  end
  local rule_w = (avail and nat > avail) and avail or nat
  for k = 1, #blocks do
    if blocks[k].rule then
      local target = size_col_rule(blocks[k], rule_w, chars)
      if target > w then
        w = target
      end
      if target > nat then
        nat = target
      end
    end
  end
  local lines, src = {}, {}
  for _, b in ipairs(blocks) do
    for j, line in ipairs(b.lines) do
      lines[#lines + 1] = line
      src[#src + 1] = (b.src and b.src[j]) or 0
    end
  end

  -- Horizontal placement of each line inside the column.  An explicit justify
  -- fills the width the column was given and packs the lines against the
  -- chosen edge, so `left` really does leave them at the left instead of
  -- letting the renderer centre the block.  Without one the block is left as
  -- it is and the renderer centres it; `edges` has nothing to spread in a
  -- single column, so it is treated the same as no justify.
  local width = w
  local jst = opts.justify
  if avail and avail > w and jst and jst ~= "edges" then
    width = avail
  end
  for i = 1, #lines do
    if width > text.dwidth(lines[i]) then
      if width == avail and jst == "right" then
        lines[i] = text.pad_left(lines[i], width)
      elseif width == avail and jst == "center" then
        lines[i] = text.center(lines[i], width)
      else
        lines[i] = text.pad_right(lines[i], width)
      end
    end
  end
  w = width
  if chars.join then
    join_rules(lines, chars)
  end
  if h == 0 then
    return empty_block()
  end
  return { w = w, h = h, lines = lines, src = src, natural = nat }
end

local function layout_row(node, avail, opts)
  local chars = rule_chars(opts)
  local children = node.children
  local n = #children
  if n == 0 then
    return empty_block()
  end
  local gap = node.table and (opts.gap or 1) or 0
  local nats = {}
  local nat_total = 0
  for i, child in ipairs(children) do
    nats[i] = measure(child, opts)
    nat_total = nat_total + nats[i]
  end
  local total = nat_total + gap * (n - 1)
  local widths = nats
  if avail and total > avail then
    widths = distribute(nats, math.max(0, avail - gap * (n - 1)))
  end

  local blocks = {}
  local h = 1
  for i, child in ipairs(children) do
    local b = fit_width(layout(child, widths[i], opts), widths[i])
    blocks[i] = b
    if b.h > h then
      h = b.h
    end
  end

  -- A rule in a row is a divider, so it needs the row's full height.
  for i, child in ipairs(children) do
    if child.type == "rule" then
      blocks[i] = size_row_rule(blocks[i], h, chars)
    end
  end
  local align = opts.align or "top"
  local cell_align = opts.cell_align or "center"

  -- spare width the row can share out between its cells (justify)
  local visible, base = 0, 0
  for _, b in ipairs(blocks) do
    if b.w > 0 then
      visible = visible + 1
      base = base + b.w
    end
  end
  base = base + gap * math.max(0, visible - 1)
  local free = (avail and avail > base) and (avail - base) or 0
  local left_pad, gap_list = justify_row(opts.justify, visible, free, gap)
  -- any explicit justify fills the width it was given, so `left` really does
  -- pack the row against the left edge instead of letting the renderer centre
  -- the whole block
  local target = (free > 0 and opts.justify ~= nil) and avail or nil

  local lines, src = {}, {}
  for r = 1, h do
    local parts = {}
    local row_line = 0
    local placed = 0
    if left_pad > 0 then
      parts[#parts + 1] = string.rep(" ", left_pad)
    end
    for i, b in ipairs(blocks) do
      local off = vertical_offset(align, h, b.h)
      local idx = r - off
      if row_line == 0 and b.src and idx >= 1 and idx <= b.h then
        row_line = b.src[idx] or 0
      end
      -- an empty cell is not content, so it does not contribute its gap
      if b.w > 0 then
        if placed > 0 then
          parts[#parts + 1] = string.rep(" ", gap_list and gap_list[placed] or gap)
        end
        parts[#parts + 1] = place(b.lines[idx], b.w, cell_align)
        placed = placed + 1
      end
    end
    lines[r] = table.concat(parts)
    if target then
      lines[r] = text.pad_right(lines[r], target)
    end
    src[r] = row_line
  end
  local w = 0
  for r = 1, h do
    local lw = text.dwidth(lines[r])
    if lw > w then
      w = lw
    end
  end
  return { w = w, h = h, lines = lines, src = src, natural = base }
end

layout_grid = function(node, avail, opts)
  local chars = rule_chars(opts)
  local rows, cols = node.rows or 0, node.cols or 0
  if rows == 0 or cols == 0 then
    return empty_block()
  end
  local gap = opts.gap or 1
  local cells = node.children

  local colw = {}
  for c = 1, cols do
    colw[c] = 0
  end
  for r = 1, rows do
    for c = 1, cols do
      local cell = cells[(r - 1) * cols + c]
      local nat = cell and measure(cell, opts) or 0
      if cell and cell.type == "rule" then
        -- a divider still needs its one column
        nat = 1
      end
      if nat > colw[c] then
        colw[c] = nat
      end
    end
  end

  local nat_total = gap * (cols - 1)
  for c = 1, cols do
    nat_total = nat_total + colw[c]
  end
  if avail and nat_total > avail then
    colw = distribute(colw, math.max(0, avail - gap * (cols - 1)))
  end

  local blocks, rowh = {}, {}
  for r = 1, rows do
    rowh[r] = 1
  end
  for r = 1, rows do
    for c = 1, cols do
      local idx = (r - 1) * cols + c
      local cell = cells[idx]
      local b
      if cell then
        b = fit_width(layout(cell, colw[c], opts), colw[c])
      else
        b = { w = colw[c], h = 1, lines = { string.rep(" ", colw[c]) }, src = { 0 } }
      end
      blocks[idx] = b
      if b.h > rowh[r] then
        rowh[r] = b.h
      end
    end
  end
  -- a rule in a grid row is a divider spanning that row
  for r = 1, rows do
    for c = 1, cols do
      local idx = (r - 1) * cols + c
      local cell = cells[idx]
      if cell and cell.type == "rule" then
        blocks[idx] = size_row_rule(blocks[idx], rowh[r], chars)
      end
    end
  end

  -- A `@grid`'s cells take their horizontal alignment from `cell_align` and,
  -- failing that, from the horizontal half of `@align`.  `edges` is not an
  -- alignment of its own -- it spreads the columns out to the edges of the
  -- block -- so it stays a block-level justify.  Grids default to top / centre.
  local from_rows = node.from_rows == true
  local cell_align = opts.cell_align
  if cell_align == nil and not from_rows and opts.justify ~= "edges" then
    cell_align = opts.justify
  end
  cell_align = cell_align or "center"
  local align = opts.align or "top"

  -- spare width the grid can share out between its columns (justify)
  local visible, base = 0, 0
  for c = 1, cols do
    if colw[c] > 0 then
      visible = visible + 1
      base = base + colw[c]
    end
  end
  base = base + gap * math.max(0, visible - 1)
  local free = (avail and avail > base) and (avail - base) or 0
  -- `edges` is the one horizontal `@align` value that spreads a grid's block:
  -- it pulls the columns out until the first and last touch the edges.  A bare
  -- `|` row spreads for every justify, as it always did.
  local jst = opts.justify
  if not from_rows and jst ~= "edges" then
    jst = nil
  end
  local left_pad, gap_list = justify_row(jst, visible, free, gap)
  local target = (free > 0 and jst ~= nil) and avail or nil

  local lines, src = {}, {}
  for r = 1, rows do
    for sub = 1, rowh[r] do
      local parts = {}
      local row_line = 0
      local placed = 0
      if left_pad > 0 then
        parts[#parts + 1] = string.rep(" ", left_pad)
      end
      for c = 1, cols do
        local b = blocks[(r - 1) * cols + c]
        local off = vertical_offset(align, rowh[r], b.h)
        local idx = sub - off
        if row_line == 0 and b.src and idx >= 1 and idx <= b.h then
          row_line = b.src[idx] or 0
        end
        -- an empty column is not content, so it does not contribute its gap
        if colw[c] > 0 then
          if placed > 0 then
            parts[#parts + 1] = string.rep(" ", gap_list and gap_list[placed] or gap)
          end
          local cell_line = (idx >= 1 and idx <= b.h) and b.lines[idx] or ""
          parts[#parts + 1] = place(cell_line, colw[c], cell_align)
          placed = placed + 1
        end
      end
      local line = table.concat(parts)
      if target then
        line = text.pad_right(line, target)
      end
      lines[#lines + 1] = line
      src[#src + 1] = row_line
    end
  end

  local w = 0
  for i = 1, #lines do
    local lw = text.dwidth(lines[i])
    if lw > w then
      w = lw
    end
  end
  return { w = w, h = #lines, lines = lines, src = src, natural = base }
end

--- Lay a node out, optionally constrained to `avail` display columns.
layout = function(node, avail, opts)
  opts = opts or {}
  if node then
    opts = merged_opts(opts, node)
  end
  if not node then
    return empty_block()
  end
  if node.type == "text" then
    return layout_text(node, avail, opts)
  elseif node.type == "box" then
    if node.dir == "col" then
      return layout_col(node, avail, opts)
    end
    return layout_row(node, avail, opts)
  elseif node.type == "grid" then
    return layout_grid(node, avail, opts)
  elseif node.type == "rule" then
    -- a placeholder: the container that owns the rule gives it its size
    return { w = 0, h = 1, lines = { "" }, src = { node.line or 0 }, rule = node }
  end
  return empty_block()
end

M.layout = layout

--- Convenience: lay out and return just the lines.
function M.lines(node, avail, opts)
  return layout(node, avail, opts).lines
end

return M
