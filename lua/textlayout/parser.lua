-- lua/textlayout/parser.lua
-- Turns plain text into a layout AST.
--
-- Symbols (all configurable via `opts.symbols`):
--
--   >          advance to the next row or column, at the start of a line
--   |          advance to the next column   (separator of a row container)
--   [ ... ]    open/close a nested layer; it flips row/col
--   @row [ ... ]  force that layer to flow (a row container)
--   @col [ ... ]  force that layer to stack (a column container)
--   @grid [ ... ]  force that layer to be a grid: its cells line up in rows and columns
--   @name(arg) layout directive for the group or row that follows
--   { ... }    meta-text
--   \          escape the next character
--
-- AST nodes:
--   { type = "text", parts = { {kind="text", value=s} | {kind="expr", value=s} } }
--   { type = "box",  dir = "row"|"col", gap = n, children = {...} }
--   { type = "grid", rows = r, cols = c, gap = n, children = {...} }
--   { type = "rule", dashes = n }
--
-- Children of a grid are stored row-major: index = (row - 1) * cols + col.

local util = require("textlayout.util")

local M = {}

M.default_symbols = {
  col_sep = "|",
  -- A cell of dashes this long (or longer) is a rule; see `rule_node`.
  rule = "-----",
  next = ">",
  open = "[",
  close = "]",
  escape = "\\",
  meta_open = "{",
  meta_close = "}",
  directive = "@",
}

-- Layout directives that retune the group or row they precede.  Each of these
-- takes a `(value)` argument, and `@align`
-- takes up to two: the vertical alignment, then the horizontal one.
local option_directives = {
  gap = true,
  align = true,
  cell_align = true,
  align_columns = true,
}

-- Directives that decide how the `[ ... ]` layer they belong to lays out: a
-- flow (row), a stack (col) or a grid of aligned cells.  They take no argument
-- and are only read where they can mean something: right in front of a layer,
-- or as the first thing inside one.
local layer_directives = { row = "row", col = "col", grid = "grid" }

--- The values `@align` accepts for its first (vertical) and second
-- (horizontal) argument.  `edges` spreads the cells out until the first and
-- last touch the edges of the row, the way CSS `space-between` does.
local vertical_align = { top = true, center = true, bottom = true }
local horizontal_align = { left = true, center = true, right = true, edges = true }

--- Turn a directive's argument into the option assignments it stands for, or
-- nil when it is malformed.  Most directives set one option; `@align` sets the
-- vertical alignment and, when it is given, the horizontal one.
local function parse_directive(name, arg)
  if name == "gap" then
    local n = tonumber(arg)
    if n and n >= 0 and n == math.floor(n) then
      return { { gap = n } }
    end
    return nil
  elseif name == "align" then
    -- `@align(vertical)`, `@align(vertical, horizontal)` or `@align(, horizontal)`
    local v, h = string.match(arg, "^%s*([^,]*)%s*,%s*(.-)%s*$")
    if v == nil then
      v, h = arg, nil
    end
    v = string.gsub(v or "", "^%s*(.-)%s*$", "%1")
    h = h and string.gsub(h, "^%s*(.-)%s*$", "%1") or nil
    local out = {}
    if v ~= "" then
      if vertical_align[v] then
        out[#out + 1] = { align = v }
      elseif h == nil and horizontal_align[v] then
        -- a lone horizontal value, e.g. `@align(edges)`
        out[#out + 1] = { justify = v }
      else
        return nil
      end
    end
    if h ~= nil and h ~= "" then
      if not horizontal_align[h] then
        return nil
      end
      out[#out + 1] = { justify = h }
    end
    if #out == 0 then
      return nil
    end
    return out
  elseif name == "cell_align" then
    if arg == "left" or arg == "center" or arg == "right" then
      return { { cell_align = arg } }
    end
    return nil
  elseif name == "align_columns" then
    if arg == "true" then
      return { { align_columns = true } }
    elseif arg == "false" then
      return { { align_columns = false } }
    end
    return nil
  end
  return nil
end

----------------------------------------------------------------------
-- Source normalisation
----------------------------------------------------------------------

--- Expand tabs, strip trailing whitespace and remove the common leading
-- indentation so that indented documents render the way they look.
local function normalize(src, opts)
  local tabstop = opts.tabstop or 4
  if tabstop < 1 then
    tabstop = 4
  end
  local lines = {}
  for line in string.gmatch(src .. "\n", "([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  -- a trailing newline produces one spurious empty entry
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end

  local out = {}
  for i, line in ipairs(lines) do
    if tabstop > 1 then
      line = string.gsub(line, "\t", string.rep(" ", tabstop))
    end
    if opts.trim_trailing ~= false then
      line = string.gsub(line, "[ \t]+$", "")
    end
    out[i] = line
  end

  if opts.dedent ~= false then
    local min_indent = nil
    for _, line in ipairs(out) do
      if line ~= "" then
        local indent = #(string.match(line, "^ *") or "")
        if not min_indent or indent < min_indent then
          min_indent = indent
        end
      end
    end
    if min_indent and min_indent > 0 then
      for i, line in ipairs(out) do
        if line ~= "" then
          out[i] = string.sub(line, min_indent + 1)
        end
      end
    end
  end

  return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- Tokenizer
----------------------------------------------------------------------

--- True when what follows `@row` / `@col` can be the layer it modifies:
-- either a `[` (spaces allowed in between) or the end of the line.
local function heads_layer(src, k, sym)
  local n = #src
  while true do
    while k <= n and string.sub(src, k, k) == " " do
      k = k + 1
    end
    local c = string.sub(src, k, k)
    if c == sym.open or c == "\n" or c == "" then
      return true
    end
    if c ~= sym.directive then
      return false
    end
    -- another directive may sit between us and the layer, and a directive is
    -- not content either, so step over it and its argument
    local name = string.match(string.sub(src, k + #sym.directive), "^([%a_][%w_]*)")
    if not name then
      return false
    end
    k = k + #sym.directive + #name
    while k <= n and string.sub(src, k, k) == " " do
      k = k + 1
    end
    if string.sub(src, k, k) == "(" then
      local close = string.find(src, ")", k, true)
      if not close then
        return false
      end
      k = close + 1
    end
  end
end

local function tokenize(src, sym, warn)
  local toks = {}
  local i, n = 1, #src
  local buf = {}
  local line = 1
  local after_open = false
  -- A line break is formatting, not a separator: the lines are joined.  The
  -- space that joins them is only emitted once something follows, so a break
  -- in front of a `[`, a `|` or a directive leaves no stray space behind.
  local soft = false
  -- Does the line we are on have anything on it at all?  A line of nothing but
  -- whitespace is a blank line, and a blank line is a row of its own.
  local content = false

  local function flush()
    if #buf > 0 then
      toks[#toks + 1] = { t = "text", v = table.concat(buf), line = line }
      buf = {}
    end
  end

  local function push(tok)
    if soft and #buf > 0 and (tok.t == "meta" or tok.t == "directive") then
      -- a line break in front of a `{ ... }` group is a separator, but a run
      -- of `{X=1}` lines with nothing else on them is not content at all
      buf[#buf + 1] = " "
    end
    soft = false
    flush()
    tok.line = line
    toks[#toks + 1] = tok
  end

  --- Append literal text, turning a pending soft break into a space first.
  local function put(str)
    if soft then
      soft = false
      if #buf > 0 then
        buf[#buf + 1] = " "
      end
    end
    buf[#buf + 1] = str
  end

  -- Whitespace after a break character is padding, not content: `>   a`
  -- opens an item whose text is just `a`.
  local function skip_pad(k)
    while k <= n and string.sub(src, k, k) == " " do
      k = k + 1
    end
    return k
  end

  -- A break character on the very first line just opens the first item.
  do
    local k = 1
    while k <= n and string.sub(src, k, k) == " " do
      k = k + 1
    end
    if k <= n and string.sub(src, k, k + #sym.next - 1) == sym.next then
      i = skip_pad(k + #sym.next)
    end
  end

  while i <= n do
    local start = i
    local c = string.sub(src, i, i)
    local was_after_open = after_open
    after_open = false
    if c ~= " " and c ~= "\n" then
      content = true
    end
    if c == sym.escape then
      local d = string.sub(src, i + 1, i + 1)
      if d == "" then
        put(c)
        i = i + 1
      elseif d == "\n" then
        -- `\` at the end of a line: a break that does not break anything
        soft = true
        i = i + 2
      else
        put(d)
        i = i + 2
      end
    elseif c == sym.col_sep then
      push({ t = "col" })
      i = i + 1
    elseif c == "\n" then
      local j = i + 1
      while j <= n and string.sub(src, j, j) == " " do
        j = j + 1
      end
      local d = string.sub(src, j, j)
      local marker = string.sub(src, j, j + #sym.next - 1) == sym.next
      -- A row starts at each blank line and at each line that opens with the
      -- break character; the two mean the same thing.  A line of nothing but
      -- directives is invisible: it starts no row and leaves the rows around
      -- it alone.
      if marker then
        push({ t = "row" })
        i = skip_pad(j + #sym.next)
      elseif not content then
        push({ t = "row" })
        i = i + 1
      elseif d == "" then
        i = i + 1
      elseif d == "\n" then
        push({ t = "row" })
        i = i + 1
      else
        soft = true
        i = j
      end
      content = false
    elseif c == sym.open then
      push({ t = "open" })
      i = i + 1
      after_open = true
    elseif c == sym.close then
      push({ t = "close" })
      i = i + 1
    elseif c == sym.meta_open then
      local j = i + 1
      local depth = 1
      local quote = nil
      while j <= n do
        local d = string.sub(src, j, j)
        if quote then
          if d == "\\" then
            j = j + 2
          elseif d == quote then
            quote = nil
            j = j + 1
          else
            j = j + 1
          end
        elseif d == '"' or d == "'" then
          quote = d
          j = j + 1
        elseif d == sym.meta_open then
          depth = depth + 1
          j = j + 1
        elseif d == sym.meta_close then
          depth = depth - 1
          if depth == 0 then
            break
          end
          j = j + 1
        else
          j = j + 1
        end
      end
      if depth ~= 0 then
        warn("unterminated meta group; rendering it literally")
        put(string.sub(src, i))
        i = n + 1
      else
        push({ t = "meta", v = string.sub(src, i + 1, j - 1) })
        i = j + 1
      end
    elseif c == sym.directive then
      local j = i + #sym.directive
      local name = string.match(string.sub(src, j), "^([%a_][%w_]*)")
      if name and layer_directives[name] and (was_after_open or heads_layer(src, j + #name, sym)) then
        -- swallow the spaces up to the `[` so they do not become content
        local stop = j + #name
        while string.sub(src, stop, stop) == " " do
          stop = stop + 1
        end
        push({ t = "directive", key = "layer", value = layer_directives[name] })
        i = stop
      elseif name and option_directives[name] then
        local k = j + #name
        while string.sub(src, k, k) == " " do
          k = k + 1
        end
        local arg, stop
        if string.sub(src, k, k) == "(" then
          local close = string.find(src, ")", k, true)
          if close then
            arg = string.sub(src, k + 1, close - 1)
            stop = close + 1
          end
        end
        local assigns = stop and parse_directive(name, arg)
        if assigns ~= nil then
          -- whitespace between directives (or indenting one) separates them,
          -- it is not content
          if #buf > 0 and string.match(table.concat(buf), "^%s*$") then
            buf = {}
          end
          for _, a in ipairs(assigns) do
            local key, value = next(a)
            push({ t = "directive", key = key, value = value })
          end
          i = stop
        else
          warn("malformed @" .. name .. " directive; rendering it literally")
          put(string.sub(src, i, (stop or (j + #name)) - 1))
          i = stop or (j + #name)
        end
      else
        put(c)
        i = i + 1
      end
    else
      put(c)
      i = i + 1
    end

    local _, nls = string.gsub(string.sub(src, start, i - 1), "\n", "")
    line = line + nls
  end
  flush()
  toks[#toks + 1] = { t = "eof" }
  return toks
end

----------------------------------------------------------------------
-- Parser
----------------------------------------------------------------------

local function peek(S)
  return S.toks[S.i]
end

local function advance(S)
  local t = S.toks[S.i]
  S.i = S.i + 1
  return t
end

local function is_stop(tok, stops)
  return tok.t == "eof" or tok.t == "close" or stops[tok.t] == true
end

local function new_text()
  return { type = "text", parts = {} }
end

local function push_literal(node, s)
  if s == "" then
    return
  end
  local last = node.parts[#node.parts]
  if last and last.kind == "text" then
    last.value = last.value .. s
  else
    node.parts[#node.parts + 1] = { kind = "text", value = s }
  end
end

--- Attach any pending layout directives to `node`.
local function apply_pending(S, node)
  if next(S.pending) ~= nil then
    node.opts = node.opts or {}
    for k, v in pairs(S.pending) do
      node.opts[k] = v
    end
    S.pending = {}
  end
  return node
end

local parse_flow
local parse_stack
local parse_layer
local parse_grid

--- Turn a list of inline items into a node. More than one item means they sit
-- side by side with no gap (plain juxtaposition), e.g. `Hello [world]`.
--- Whitespace around a `|` is a separator in the source, not content, so
-- cells are trimmed before they are laid out. Juxtaposed inline items are
-- left alone, which is what makes `Hello [world]` keep its space.
local function trim_leading(node)
  if node.type ~= "text" then
    return
  end
  local first = node.parts[1]
  if first and first.kind == "text" then
    first.value = string.gsub(first.value, "^%s+", "")
    if first.value == "" then
      table.remove(node.parts, 1)
    end
  end
end

local function trim_trailing(node)
  if node.type ~= "text" then
    return
  end
  local last = node.parts[#node.parts]
  if last and last.kind == "text" then
    last.value = string.gsub(last.value, "%s+$", "")
    if last.value == "" then
      table.remove(node.parts)
    end
  end
end

local function trim_cell(items)
  if #items > 0 then
    trim_leading(items[1])
    trim_trailing(items[#items])
  end
  return items
end

--- A cell that is nothing but dashes is a rule: it draws a line across its
-- container instead of taking up room of its own, so writing `-----` under a
-- heading rules off the width the rest of the document already uses.
local function rule_node(items, line, sym)
  if #items ~= 1 then
    return nil
  end
  local node = items[1]
  local part = node.type == "text" and #(node.parts or {}) == 1 and node.parts[1]
  if not part or part.kind ~= "text" then
    return nil
  end
  local marker = sym.rule or "-----"
  local ch = string.sub(marker, 1, 1)
  if ch == "" then
    return nil
  end
  if not string.match(ch, "%w") then
    ch = "%" .. ch
  end
  local run = string.match(part.value, "^(" .. ch .. "+)$")
  if not run or #run < #marker then
    return nil
  end
  return { type = "rule", dashes = #run, line = node.line or line or 1 }
end

local function cell_to_node(items, line, sym)
  local rule = rule_node(items, line, sym)
  if rule then
    return rule
  end
  if #items == 0 then
    local node = new_text()
    node.line = line or 1
    return node
  end
  if #items == 1 then
    local node = items[1]
    if node.line == nil then
      node.line = line or 1
    end
    return node
  end
  return {
    type = "box",
    dir = "row",
    gap = 0,
    line = line or items[1].line or 1,
    children = items,
  }
end

--- The kind forced on the next `[ ... ]` layer: a `@row` / `@col`
-- directive either waiting in front of it or written first inside it.
-- Returns "row", "col" or nil when the layer should just alternate.
local function take_layer(S)
  local forced = S.pending.layer
  if forced then
    S.pending.layer = nil
    return forced
  end
  local tok = peek(S)
  if tok.t == "directive" and tok.key == "layer" then
    advance(S)
    return tok.value
  end
  return nil
end

--- Inline items up to the next structural separator.
local function parse_cell(S)
  local items = {}
  local cur = nil
  while true do
    local tok = peek(S)
    if is_stop(tok, { col = true, row = true }) then
      break
    end
    if tok.t == "text" then
      advance(S)
      if not cur then
        cur = new_text()
        cur.line = tok.line or 1
        items[#items + 1] = cur
      end
      push_literal(cur, tok.v)
    elseif tok.t == "meta" then
      advance(S)
      if not cur then
        cur = new_text()
        cur.line = tok.line or 1
        items[#items + 1] = cur
      end
      cur.parts[#cur.parts + 1] = { kind = "expr", value = tok.v }
    elseif tok.t == "directive" then
      advance(S)
      S.pending[tok.key] = tok.value
    elseif tok.t == "open" then
      advance(S)
      cur = nil
      local forced = take_layer(S)
      -- a newline straight after `[` is formatting, not a blank line
      if peek(S).t == "row" then
        advance(S)
      end
      local outer = S.pending
      S.pending = {}
      local group = parse_layer(S, forced)
      if next(S.pending) ~= nil then
        S.warn("layout directive has no following group")
        S.pending = {}
      end
      S.pending = outer
      -- and neither is a blank line just before `]`
      while #group.children > 0 do
        local tail = group.children[#group.children]
        if tail.type == "text" and #tail.parts == 0 then
          table.remove(group.children)
        else
          break
        end
      end
      apply_pending(S, group)
      items[#items + 1] = group
      if peek(S).t == "close" then
        advance(S)
      else
        S.warn("unclosed '" .. S.sym.open .. "'")
      end
    else
      break
    end
  end
  return items
end

--- One line: cells separated by the column symbol.
local function parse_row(S)
  local line = peek(S).line or 1
  local cells = { parse_cell(S) }
  while peek(S).t == "col" do
    advance(S)
    cells[#cells + 1] = parse_cell(S)
  end
  if #cells == 1 then
    local node = cell_to_node(trim_cell(cells[1]), line, S.sym)
    if node.type == "text" and #node.parts == 0 then
      -- a directive-only line leaves its options for the next node
      return node
    end
    return apply_pending(S, node)
  end
  local children = {}
  for i = 1, #cells do
    children[i] = cell_to_node(trim_cell(cells[i]), line, S.sym)
  end
  return apply_pending(S, {
    type = "box",
    dir = "row",
    gap = S.gap,
    table = true,
    line = line,
    children = children,
  })
end

--- A flow container: `|` starts the next cell of the current line and a
-- newline starts a new line. This is what the document root and every
-- `@row [...]` layer produce.
parse_flow = function(S)
  local outer = S.kind
  S.kind = "row"
  local line = peek(S).line or 1
  local lines = {}
  -- A directive written in front of a plain line has no group or row of its
  -- own to sit on, so it is lifted onto the flow itself: this is what lets
  -- `@align(, right)` place a document made of prose.
  local flow_opts = nil
  while true do
    local tok = peek(S)
    if tok.t == "eof" or tok.t == "close" then
      break
    end
    if tok.t == "directive" then
      -- a line of nothing but directives configures the next group or row and
      -- leaves no blank line behind.
      S.pending[tok.key] = tok.value
      advance(S)
      if peek(S).t == "row" then
        advance(S)
      end
    elseif tok.t == "row" then
      -- a separator with nothing before it (or a run of them) is a blank line
      local blank = new_text()
      blank.line = tok.line or line
      lines[#lines + 1] = blank
      advance(S)
    else
      local node = parse_row(S)
      if node.type == "text" and node.opts then
        flow_opts = flow_opts or {}
        for k, v in pairs(node.opts) do
          flow_opts[k] = v
        end
        node.opts = nil
      end
      lines[#lines + 1] = node
      if peek(S).t == "row" then
        advance(S)
      end
    end
  end
  S.kind = outer
  return { type = "box", dir = "col", gap = 0, line = line, children = lines, opts = flow_opts }
end

--- A stacking container: a newline *and* `|` both separate stacked items.
-- This is what a `[...]` layer produces when its parent is a flow.
parse_stack = function(S)
  local outer = S.kind
  S.kind = "col"
  local line = peek(S).line or 1
  local items = {}
  while true do
    local tok = peek(S)
    if tok.t == "eof" or tok.t == "close" then
      break
    end
    if tok.t == "directive" then
      -- a line of nothing but directives configures the next group or item
      S.pending[tok.key] = tok.value
      advance(S)
      local sep = peek(S)
      if sep.t == "row" or sep.t == "col" then
        advance(S)
      end
    elseif tok.t == "col" or tok.t == "row" then
      -- a separator with nothing before it is a blank item
      local blank = new_text()
      blank.line = tok.line or line
      items[#items + 1] = blank
      advance(S)
    else
      local node = cell_to_node(trim_cell(parse_cell(S)), tok.line, S.sym)
      apply_pending(S, node)
      items[#items + 1] = node
      local sep = peek(S)
      if sep.t == "col" or sep.t == "row" then
        advance(S)
      end
    end
  end
  S.kind = outer
  return { type = "box", dir = "col", gap = 0, line = line, children = items }
end

--- Parse a `[...]` layer. Layers alternate: a layer inside a flow stacks and
-- a layer inside a stack flows.  `forced` comes from a `@row` / `@col` /
-- `@grid` directive.
parse_layer = function(S, forced)
  local kind = forced or (S.kind == "row" and "col" or "row")
  if kind == "grid" then
    return parse_grid(S)
  end
  if kind == "row" then
    return parse_flow(S)
  end
  return parse_stack(S)
end

--- A grid container.  The layer is read a row at a time -- a `|` starts the
-- next cell of the current row and a newline or `>` starts the next row -- and
-- every row is padded out to the widest one, so the columns line up all the way
-- down.  This is what a `@grid [...]` layer produces; a subdivision inside a
-- cell lays out normally unless it is a `@grid` too.
parse_grid = function(S)
  local outer = S.kind
  S.kind = "row"
  local line = peek(S).line or 1
  local rows = {}
  local cols = 0
  local gopts = nil
  while true do
    local tok = peek(S)
    if tok.t == "eof" or tok.t == "close" then
      break
    end
    if tok.t == "directive" then
      -- a line of nothing but directives configures the grid itself
      S.pending[tok.key] = tok.value
      advance(S)
      if peek(S).t == "row" then
        advance(S)
      end
    elseif tok.t == "row" then
      -- a separator with nothing in front of it separates rows; it is not a row
      advance(S)
    else
      local node = parse_row(S)
      if node.opts then
        gopts = gopts or {}
        for k, v in pairs(node.opts) do
          gopts[k] = v
        end
        node.opts = nil
      end
      local cells
      if node.type == "box" and node.dir == "row" then
        cells = node.children
      else
        cells = { node }
      end
      rows[#rows + 1] = cells
      if #cells > cols then
        cols = #cells
      end
      if peek(S).t == "row" then
        advance(S)
      end
    end
  end
  S.kind = outer
  if #rows == 0 or cols == 0 then
    return { type = "box", dir = "col", gap = 0, line = line, children = {}, opts = gopts }
  end
  -- cells are stored row-major, padded with empty ones so every row is `cols`
  -- wide and the grid keeps its shape
  local cells = {}
  for r = 1, #rows do
    local row = rows[r]
    for c = 1, cols do
      cells[(r - 1) * cols + c] = row[c] or new_text()
    end
  end
  return {
    type = "grid",
    rows = #rows,
    cols = cols,
    gap = S.gap,
    line = line,
    children = cells,
    opts = gopts,
  }
end

local function trim_trailing_blank_lines(node)
  while #node.children > 0 do
    local last = node.children[#node.children]
    if last.type == "text" and #last.parts == 0 then
      table.remove(node.children)
    else
      break
    end
  end
end

--- Parse `src` into an AST.
-- @return ast, warnings
function M.parse(src, opts)
  opts = opts or {}
  local sym = util.merge(M.default_symbols, opts.symbols)
  local warnings = {}
  local normalized = normalize(src, opts)
  local toks = tokenize(normalized, sym, function(msg)
    warnings[#warnings + 1] = msg
  end)

  local S = {
    toks = toks,
    i = 1,
    gap = opts.gap or 1,
    pending = {},
    kind = "row",
    sym = sym,
    warn = function(msg)
      warnings[#warnings + 1] = msg
    end,
  }

  local doc = parse_flow(S)
  while peek(S).t == "close" do
    S.warn("unmatched '" .. sym.close .. "'")
    advance(S)
    local more = parse_flow(S)
    for _, child in ipairs(more.children) do
      doc.children[#doc.children + 1] = child
    end
  end
  if peek(S).t ~= "eof" then
    S.warn("unexpected trailing content")
  end
  if next(S.pending) ~= nil then
    S.warn("layout directive has no following group")
  end
  trim_trailing_blank_lines(doc)
  return doc, warnings
end

--- Exposed for tests.
M.normalize = normalize
M.tokenize = tokenize

return M
