-- lua/textlayout/inline.lua
-- Shows a `.tlmd` document as a laid-out preview in its own window.
--
-- The preview is a read-only scratch buffer that is swapped into the window;
-- the file buffer itself is never modified, so undo, `:w`, LSP, git signs and
-- autosave plugins keep seeing the text you actually wrote.
--
-- A `.tlmd` window shows the preview as soon as the buffer is displayed.  From
-- then on nothing moves by itself: `inline.toggle()` (bound to
-- `inline.toggle_key` in NORMAL mode) flips between the two ways of reading a
-- document, keeping the cursor on the line you were on:
--
--     preview   one window, the whole layout
--     split     the real text, with the layout live in a pane beside it
--
-- `inline.open()` / `inline.close()` go straight to one of them, and
-- `inline.split()` opens the pane beside the text.

local api = vim.api

local textlayout = require("textlayout")
local meta = require("textlayout.meta")
local session = require("textlayout.session")

local M = {}

local GLOBAL_AUGROUP = "textlayout-inline"

--- source bufnr -> session { render_buf, line_map, augroup, ... }
local sessions = {}

--- render bufnr -> source bufnr
local render_src = {}

--- win -> { src = source bufnr, line = source line, wanted = "preview"|"text" }
local windows = {}

--- win -> true while a deferred show is queued for that window
local pending = {}

--- source bufnr -> { text_win, preview_win } while the preview is split
--- beside the text rather than filling the window on its own.
local splits = {}

local globals_ready = false

--- True while a session file is being read: the session restores both the
-- text and the layout, so nothing may swap itself in while it is read.
local loading_session = false

--- Set once so a repeated BufWinEnter cannot repeat the message.
local warned_hidden = false

--- The last unexpected error, kept so it can be inspected instead of shown.
local last_error = nil

--- Wrap a callback so it can never raise.  These run on every keystroke: an
-- error escaping into an autocmd is worse than a pane that is one edit behind.
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      last_error = tostring(err)
    end
  end
end

--- The last unexpected error, or nil.
function M.last_error()
  return last_error
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function config()
  return textlayout.get_config()
end

local function inline_config()
  return config().inline or {}
end

local function editor_cols()
  local ok, cols = pcall(function()
    return vim.o.columns
  end)
  if ok and type(cols) == "number" and cols > 0 then
    return cols
  end
  return 80
end

--- Accept nil/0/current-buffer/being-inside-the-preview and return the source.
function M.resolve(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  return render_src[bufnr] or bufnr
end

function M.session(bufnr)
  return sessions[M.resolve(bufnr)]
end

local function ft_matches(bufnr)
  local fts = inline_config().filetypes or { "tlmd" }
  local ft = vim.bo[bufnr].filetype
  for _, want in ipairs(fts) do
    if want == ft then
      return true
    end
  end
  return false
end

--- Columns the renderer may use in `win` (window width minus the gutter).
local function window_width(win)
  local cfg = inline_config()
  if cfg.width then
    return math.max(1, cfg.width)
  end
  local ok, width = pcall(api.nvim_win_get_width, win)
  if not ok or type(width) ~= "number" or width < 1 then
    return editor_cols()
  end
  local textoff = 0
  local ok2, info = pcall(vim.fn.getwininfo, win)
  if ok2 and type(info) == "table" and info[1] and info[1].textoff then
    textoff = info[1].textoff
  end
  return math.max(1, width - textoff)
end

--- Render `src`.  This runs while the document is being typed, so it has to
-- come back with something no matter how broken the text is: half a `[`, an
-- unterminated `{`, whatever.  A render that fails outright falls back to the
-- text exactly as it is written.
local function render_source(src, width)
  local lines = api.nvim_buf_get_lines(src, 0, -1, false)
  local ok, result = pcall(textlayout.render, table.concat(lines, "\n"), {
    width = width,
    env = meta.new_env(config().env),
  })
  if ok then
    return result
  end
  local fallback, line_map = {}, {}
  for i, line in ipairs(lines) do
    fallback[i] = line
    line_map[i] = i
  end
  if #fallback == 0 then
    fallback[1] = ""
    line_map[1] = 1
  end
  return {
    lines = fallback,
    warnings = { "could not render: " .. tostring(result) },
    width = width or 0,
    natural_width = width or 0,
    height = #fallback,
    line_map = line_map,
  }
end

--- Warnings are kept on the session rather than shown.  This runs on every
-- keystroke and a half-typed document is full of them, so the pane renders
-- something sensible (see render_source) and stays quiet; `M.warnings()`
-- has the details when you want them.
local function report_warnings(st, warnings)
  st.warnings = warnings
end

local function set_render_lines(pbuf, lines)
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[pbuf].modifiable = true
  api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.bo[pbuf].modifiable = false
  vim.bo[pbuf].modified = false
end

--- Rendered line that best represents source line `sline`.
local function render_line_for(line_map, sline)
  local best = 1
  for i, s in ipairs(line_map) do
    if s == sline then
      return i
    end
    if s and s ~= 0 and s <= sline then
      best = i
    end
  end
  return best
end

--- Source line behind rendered line `rline` (0 means "synthetic").
local function source_line_for(line_map, rline)
  for i = math.min(rline, #line_map), 1, -1 do
    local s = line_map[i]
    if s and s ~= 0 then
      return s
    end
  end
  return 1
end

local function first_nonblank(bufnr, lnum)
  local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local col = line:find("[^%s]")
  if not col then
    return 0
  end
  return col - 1
end

--- Is the preview currently open beside the text of `src`?
local function split_is_open(src)
  local sp = splits[src]
  if not sp then
    return false
  end
  if not (api.nvim_win_is_valid(sp.text_win) and api.nvim_win_is_valid(sp.preview_win)) then
    splits[src] = nil
    return false
  end
  return true
end

--- Close `win` if it is not the last window standing.
local function close_window(win)
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  if #api.nvim_list_wins() <= 1 then
    return
  end
  windows[win] = nil
  pending[win] = nil
  pcall(api.nvim_win_close, win, true)
end

--- Width for the preview pane when it sits beside the text.
local function pane_width(st)
  local cfg = inline_config()
  if cfg.split_width then
    return math.max(1, cfg.split_width)
  end
  local cols = editor_cols()
  -- Never take more than `cols - 20` columns, so the text keeps some room.
  local room = math.max(20, cols - 20)
  local natural = st.natural_width or 0
  if natural <= 0 then
    return math.max(1, math.floor(cols / 2))
  end
  return math.max(20, math.min(natural, room))
end

local function window_shows_render(win, st)
  return st ~= nil
    and st.render_buf ~= nil
    and api.nvim_win_is_valid(win)
    and api.nvim_win_get_buf(win) == st.render_buf
end

local function bind_toggle(bufnr, src)
  local key = inline_config().toggle_key
  if not key or key == false or key == "" then
    return
  end
  vim.keymap.set("n", key, function()
    M.toggle(src)
  end, {
    buffer = bufnr,
    silent = true,
    desc = "textlayout: swap between the preview and the text",
  })
end

----------------------------------------------------------------------
-- The preview buffer
----------------------------------------------------------------------

local function create_render_buffer(src)
  local pbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].buftype = "acwrite"
  vim.bo[pbuf].bufhidden = "hide"
  vim.bo[pbuf].swapfile = false
  vim.bo[pbuf].undolevels = -1
  vim.bo[pbuf].modifiable = false
  vim.bo[pbuf].filetype = inline_config().render_filetype or "textlayout"
  session.mark(pbuf, api.nvim_buf_get_name(src))
  render_src[pbuf] = src

  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = pbuf,
    desc = "textlayout: write the source text, never the preview",
    callback = guard(function()
      M.write_source(src)
    end),
  })
  bind_toggle(pbuf, src)
  return pbuf
end

local function ensure_render_buffer(st, src)
  if st.render_buf and api.nvim_buf_is_valid(st.render_buf) then
    return st.render_buf
  end
  st.render_buf = create_render_buffer(src)
  return st.render_buf
end

----------------------------------------------------------------------
-- Swapping
----------------------------------------------------------------------

--- Show the preview of `src` in `win`, keeping the cursor on the same line.
function M.show(win, src)
  local st = sessions[src]
  if not st or not api.nvim_win_is_valid(win) then
    return
  end
  local pbuf = ensure_render_buffer(st, src)

  local cur = api.nvim_win_get_buf(win)
  local sline
  if cur == src then
    sline = api.nvim_win_get_cursor(win)[1]
  elseif windows[win] and windows[win].src == src then
    sline = windows[win].line
  else
    sline = api.nvim_win_get_cursor(win)[1]
  end
  sline = math.max(1, math.min(sline, api.nvim_buf_line_count(src)))
  windows[win] = { src = src, line = sline, wanted = "preview" }

  local result = render_source(src, window_width(win))
  st.line_map = result.line_map or {}
  st.natural_width = result.natural_width
  set_render_lines(pbuf, result.lines)
  report_warnings(st, result.warnings)

  if cur ~= pbuf then
    api.nvim_win_set_buf(win, pbuf)
  end
  pcall(api.nvim_win_set_cursor, win, { render_line_for(st.line_map, sline), 0 })
end

--- Put the real text back in `win`, keeping the cursor on the same line.
function M.hide(win, src)
  local st = sessions[src]
  if not st or not api.nvim_win_is_valid(win) then
    return
  end
  local cur = api.nvim_win_get_buf(win)
  if cur ~= st.render_buf then
    -- already looking at the real text; leave the cursor where the user put it
    windows[win] = { src = src, line = api.nvim_win_get_cursor(win)[1], wanted = "text" }
    return
  end
  local rline = api.nvim_win_get_cursor(win)[1]
  local sline = source_line_for(st.line_map, rline)
  sline = math.max(1, math.min(sline, api.nvim_buf_line_count(src)))
  windows[win] = { src = src, line = sline, wanted = "text" }
  api.nvim_win_set_buf(win, src)
  pcall(api.nvim_win_set_cursor, win, { sline, first_nonblank(src, sline) })
end

--- Collapse the split around `win`, leaving `win` showing the preview.
local function collapse_split(win, src)
  local sp = splits[src]
  if not sp then
    return
  end
  splits[src] = nil
  local other = (win == sp.text_win) and sp.preview_win or sp.text_win
  if win == sp.text_win then
    -- this window takes the preview back
    M.show(win, src)
  end
  if other ~= win then
    close_window(other)
  end
  if api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  end
end

--- Show the preview in the current window, on its own.
function M.open(bufnr)
  local win = api.nvim_get_current_win()
  local src = M.resolve(bufnr or api.nvim_win_get_buf(win))
  local st = sessions[src] or M.attach(src)
  if not st then
    return nil
  end
  collapse_split(win, src)
  M.show(win, src)
  return "preview"
end

--- Show the real text in the current window, closing the pane beside it.
function M.close(bufnr)
  local win = api.nvim_get_current_win()
  local src = M.resolve(bufnr or api.nvim_win_get_buf(win))
  if not sessions[src] then
    return nil
  end
  if split_is_open(src) then
    local sp = splits[src]
    splits[src] = nil
    local other = (win == sp.text_win) and sp.preview_win or sp.text_win
    M.hide(win, src)
    if other ~= win then
      close_window(other)
    end
  end
  M.hide(win, src)
  return "text"
end

--- Show the preview in a pane beside the real text.
-- The window you are in keeps (or takes back) the text; the layout opens next
-- to it, and the cursor stays where it was.
function M.split(bufnr)
  local win = api.nvim_get_current_win()
  local src = M.resolve(bufnr or api.nvim_win_get_buf(win))
  local st = sessions[src] or M.attach(src)
  if not st then
    return nil
  end
  if split_is_open(src) then
    return splits[src].preview_win
  end

  local pbuf = ensure_render_buffer(st, src)
  if api.nvim_win_get_buf(win) == pbuf then
    M.hide(win, src)
  else
    windows[win] = { src = src, line = api.nvim_win_get_cursor(win)[1], wanted = "text" }
  end
  local line = windows[win].line

  local width = pane_width(st)
  local result = render_source(src, width)
  st.line_map = result.line_map or {}
  st.natural_width = result.natural_width
  set_render_lines(pbuf, result.lines)
  report_warnings(st, result.warnings)

  local side = inline_config().split_side
  local ok = pcall(vim.cmd, (side == "left") and "topleft vsplit" or "rightbelow vsplit")
  if not ok then
    return nil
  end
  local pwin = api.nvim_get_current_win()
  if pwin == win then
    return nil
  end
  api.nvim_win_set_buf(pwin, pbuf)
  pcall(api.nvim_win_set_width, pwin, width)
  windows[pwin] = { src = src, line = line, wanted = "preview" }
  pcall(api.nvim_win_set_cursor, pwin, { render_line_for(st.line_map, line), 0 })
  splits[src] = { text_win = win, preview_win = pwin }

  api.nvim_set_current_win(win)
  return pwin
end

--- Flip between the two ways of reading the document:
-- the preview on its own, and the preview beside the text.
function M.toggle(bufnr)
  local win = api.nvim_get_current_win()
  local src = M.resolve(bufnr or api.nvim_win_get_buf(win))
  local st = sessions[src] or M.attach(src)
  if not st then
    return nil
  end

  if split_is_open(src) then
    local sp = splits[src]
    local keep = (win == sp.text_win or win == sp.preview_win) and win or sp.text_win
    collapse_split(keep, src)
    return "preview"
  end

  if st.render_buf and api.nvim_win_get_buf(win) == st.render_buf then
    -- reading the layout on its own: give the text back and put the layout
    -- beside it
    return M.split(src) and "split" or "preview"
  end

  return M.split(src) and "split" or "text"
end

--- The { text_win, preview_win } of the open split for `bufnr`, if any.
function M.split_windows(bufnr)
  local src = M.resolve(bufnr)
  if not split_is_open(src) then
    return nil
  end
  return splits[src].text_win, splits[src].preview_win
end

--- "off" | "text" | "preview" | "split" -- how `win`'s document is arranged.
function M.arrangement(win)
  win = win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then
    return "off"
  end
  local buf = api.nvim_win_get_buf(win)
  local src = M.resolve(buf)
  local st = sessions[src]
  if not st then
    return "off"
  end
  if split_is_open(src) then
    return "split"
  end
  if st.render_buf and buf == st.render_buf then
    return "preview"
  end
  return "text"
end

--- "off" | "text" | "preview" for `win` (the current window by default).
function M.status(win)
  win = win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then
    return "off"
  end
  local buf = api.nvim_win_get_buf(win)
  local st = sessions[M.resolve(buf)]
  if not st then
    return "off"
  end
  if st.render_buf and buf == st.render_buf then
    return "preview"
  end
  return "text"
end

--- Warnings from the last render of `bufnr` (empty when all is well).
function M.warnings(bufnr)
  local st = sessions[M.resolve(bufnr)]
  return (st and st.warnings) or {}
end

--- Is `win` currently showing the preview?
function M.is_preview(win)
  return M.status(win) == "preview"
end

--- Re-render every window that is currently showing `bufnr` as a preview.
function M.sync(bufnr)
  local src = M.resolve(bufnr)
  local st = sessions[src]
  if not st then
    return
  end
  local snapshot = {}
  for win, w in pairs(windows) do
    if w.src == src and window_shows_render(win, st) then
      snapshot[#snapshot + 1] = win
    end
  end
  for _, win in ipairs(snapshot) do
    M.show(win, src)
  end
end

function M.resize_all()
  local snapshot = {}
  for win, w in pairs(windows) do
    snapshot[#snapshot + 1] = { win = win, src = w.src }
  end
  for _, item in ipairs(snapshot) do
    local st = sessions[item.src]
    if st and window_shows_render(item.win, st) then
      M.show(item.win, item.src)
    end
  end
end

----------------------------------------------------------------------
-- Showing the preview for a buffer that has just been displayed
----------------------------------------------------------------------

local function on_enter()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)

  local w = windows[win]
  if w then
    local known = sessions[w.src]
    local our_preview = known and known.render_buf ~= nil and buf == known.render_buf
    if not our_preview and w.src ~= buf then
      windows[win] = nil
      w = nil
    end
  end

  if not sessions[buf] then
    return
  end
  if w and w.wanted == "text" then
    return
  end
  if pending[win] then
    return
  end
  pending[win] = true
  -- Deferred: swapping the preview in is not something to do from inside
  -- BufWinEnter/FileType of a buffer that is still being read.
  vim.schedule(guard(function()
    pending[win] = nil
    if not sessions[buf] then
      return
    end
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local now = windows[win]
    if now and now.wanted == "text" then
      return
    end
    M.show(win, buf)
  end))
end

M.on_enter = on_enter

--- Hold off until a session file has been read.
function M.begin_session_load()
  loading_session = true
end

--- Stop holding off: the layout the session had on screen is put back next.
function M.end_session_load()
  loading_session = false
end

--- Attach the documents a session restored, without changing what any window
-- shows.  A window the session put the text in keeps showing the text; one it
-- put a layout in was opened again by session.restore().
function M.attach_restored()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if M.handles(buf) and not sessions[buf] then
      M.attach(buf)
      if sessions[buf] then
        windows[win] = { src = buf, line = api.nvim_win_get_cursor(win)[1], wanted = "text" }
      end
    end
  end
end

local function ensure_global_autocmds()
  if globals_ready then
    return
  end
  globals_ready = true
  local group = api.nvim_create_augroup(GLOBAL_AUGROUP, { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "FileType" }, {
    group = group,
    desc = "textlayout: show the preview for a newly displayed .tlmd window",
    callback = guard(on_enter),
  })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    desc = "textlayout: re-fit the preview to the new window size",
    callback = guard(function()
      M.resize_all()
    end),
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = guard(function(args)
      local win = tonumber(args.match)
      if win then
        windows[win] = nil
        pending[win] = nil
        for src, sp in pairs(splits) do
          if sp.text_win == win or sp.preview_win == win then
            splits[src] = nil
          end
        end
      end
    end),
  })
end

----------------------------------------------------------------------
-- Sessions
----------------------------------------------------------------------

--- Set up `bufnr` (the current buffer by default) for in-place previewing.
function M.attach(bufnr)
  bufnr = M.resolve(bufnr or api.nvim_get_current_buf())
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if inline_config().enabled == false then
    return nil
  end
  if not ft_matches(bufnr) then
    return nil
  end
  -- Swapping the preview in leaves the file buffer hidden; refuse rather than
  -- risk losing an unsaved buffer.
  if not vim.o.hidden then
    if not warned_hidden then
      warned_hidden = true
      vim.notify("textlayout: the in-place preview needs 'hidden'", vim.log.levels.WARN)
    end
    return nil
  end
  local bufhidden = vim.bo[bufnr].bufhidden
  if bufhidden == "wipe" or bufhidden == "unload" then
    return nil
  end

  if loading_session then
    return nil
  end

  ensure_global_autocmds()

  local st = sessions[bufnr]
  if st then
    return st
  end

  st = {
    line_map = {},
    warnings = {},
    augroup = api.nvim_create_augroup("textlayout-inline:" .. bufnr, { clear = true }),
  }
  st.render_buf = create_render_buffer(bufnr)
  sessions[bufnr] = st

  bind_toggle(bufnr, bufnr)

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
    group = st.augroup,
    buffer = bufnr,
    callback = guard(function()
      M.sync(bufnr)
    end),
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = st.augroup,
    buffer = bufnr,
    callback = guard(function()
      M.detach(bufnr)
    end),
  })
  return st
end

--- Does in-place rendering own `bufnr`?  True when its filetype is one of
-- the configured ones and in-place rendering is on.
function M.handles(bufnr)
  bufnr = M.resolve(bufnr)
  if inline_config().enabled == false then
    return false
  end
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return ft_matches(bufnr)
end

--- Show the preview of `src` in `win` again, as when a session that was saved
-- with the layout on screen is loaded.  When the session also restored the
-- text beside it, the two are tied back together as the split arrangement.
--
-- @return true when the window is showing a preview again
function M.restore_window(win, src)
  if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(src) then
    return false
  end
  if not M.handles(src) or not vim.o.hidden then
    return false
  end
  local st = sessions[src] or M.attach(src)
  if not st then
    return false
  end
  -- A window that was showing the text when the session was written has to
  -- stay showing the text: the filetype plugin may already have swapped the
  -- layout into it while the session was being read.
  local others = {}
  for _, other in ipairs(api.nvim_list_wins()) do
    if other ~= win then
      local buf = api.nvim_win_get_buf(other)
      if buf == src or buf == st.render_buf then
        others[#others + 1] = other
      end
    end
  end

  M.show(win, src)

  local text_win
  for _, other in ipairs(others) do
    M.hide(other, src)
    text_win = text_win or other
  end
  if text_win then
    splits[src] = { text_win = text_win, preview_win = win }
  end
  return true
end

--- Detach every buffer that is being rendered in place.
function M.detach_all()
  local snapshot = {}
  for src in pairs(sessions) do
    snapshot[#snapshot + 1] = src
  end
  for _, src in ipairs(snapshot) do
    M.detach(src)
  end
end

--- Tear the session down and put the real text back on screen.
function M.detach(bufnr)
  local src = M.resolve(bufnr)
  local st = sessions[src]
  if not st then
    return
  end
  sessions[src] = nil

  local sp = splits[src]
  splits[src] = nil
  if sp and api.nvim_win_is_valid(sp.preview_win) and #api.nvim_list_wins() > 1 then
    windows[sp.preview_win] = nil
    pending[sp.preview_win] = nil
    pcall(api.nvim_win_close, sp.preview_win, true)
  end

  for win, w in pairs(windows) do
    if w.src == src then
      windows[win] = nil
      pending[win] = nil
      if api.nvim_win_is_valid(win) and st.render_buf and api.nvim_win_get_buf(win) == st.render_buf then
        pcall(api.nvim_win_set_buf, win, src)
      end
    end
  end

  if st.augroup then
    pcall(api.nvim_del_augroup_by_id, st.augroup)
    st.augroup = nil
  end
  if st.render_buf then
    render_src[st.render_buf] = nil
    if api.nvim_buf_is_valid(st.render_buf) then
      pcall(api.nvim_buf_delete, st.render_buf, { force = true })
    end
    st.render_buf = nil
  end
end

--- Write the real text of `src`, even though the preview is on screen.
function M.write_source(bufnr)
  local src = M.resolve(bufnr)
  local st = sessions[src]
  local ok, err = pcall(function()
    api.nvim_buf_call(src, function()
      vim.cmd("silent write")
    end)
  end)
  if not ok then
    vim.notify("textlayout: " .. tostring(err), vim.log.levels.ERROR)
  end
  if st and st.render_buf and api.nvim_buf_is_valid(st.render_buf) then
    vim.bo[st.render_buf].modified = false
  end
end

return M
