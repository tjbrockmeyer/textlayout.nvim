-- lua/textlayout/preview.lua
-- The Neovim side of the plugin: a live preview pane that always fits.

local api = vim.api
local uv = vim.uv or vim.loop

local textlayout = require("textlayout")
local meta = require("textlayout.meta")
local session = require("textlayout.session")

local M = {}

--- bufnr -> { pbuf, win, src_win, timer, augroup, last_width, warnings }
local sessions = {}

--- preview bufnr -> source bufnr, so commands still work when the cursor is
-- sitting inside the preview.
local by_preview = {}

local function config()
  return textlayout.get_config()
end

--- Headless Neovim has no UI, so `rows` may not exist yet. Fall back to the
-- usual defaults instead of blowing up.
local function editor_rows()
  local ok, rows = pcall(function()
    return vim.o.rows
  end)
  if ok and type(rows) == "number" and rows > 0 then
    return rows
  end
  return 24
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

--- Accept nil/0/current-buffer/being-inside-the-preview and return the
-- document buffer the caller actually means.
local function resolve(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  return by_preview[bufnr] or bufnr
end

local function source_text(bufnr)
  return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function float_width(pcfg)
  local cols = editor_cols()
  local want = pcfg.width or math.floor(cols * 0.6)
  want = math.max(20, want)
  return math.max(10, math.min(want, cols - 4))
end

local function float_geometry(width, height)
  local rows, cols = editor_rows(), editor_cols()
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height) / 2) - 1),
    col = math.max(0, math.floor((cols - width) / 2)),
  }
end

local function set_preview_lines(pbuf, lines)
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[pbuf].modifiable = true
  api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.bo[pbuf].modifiable = false
end

local function apply_window_options(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].spell = false
  vim.wo[win].cursorline = false
  vim.wo[win].list = false
  vim.wo[win].winfixwidth = true
end

local function apply_buffer_options(pbuf)
  vim.bo[pbuf].buftype = "nofile"
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].swapfile = false
  vim.bo[pbuf].filetype = "textlayout-preview"
  vim.bo[pbuf].modifiable = false
  vim.bo[pbuf].undolevels = -1
end



--- Render `bufnr` and push the result into the preview buffer.
function M.refresh(bufnr)
  bufnr = resolve(bufnr)
  local st = sessions[bufnr]
  if not st then
    return
  end
  if not api.nvim_buf_is_valid(st.pbuf) then
    return
  end
  if st.win and not api.nvim_win_is_valid(st.win) then
    return
  end

  local cfg = config()
  local width
  if st.win and api.nvim_win_is_valid(st.win) then
    width = api.nvim_win_get_width(st.win)
  end
  width = math.max(1, width or cfg.width or editor_cols())

  -- Runs on every keystroke, so it has to come back with something: a render
  -- that fails outright falls back to the text exactly as it is written.
  local source = source_text(bufnr)
  local ok, result = pcall(textlayout.render, source, {
    width = width,
    env = meta.new_env(cfg.env),
  })
  if not ok then
    local fallback = vim.split(source, "\n", { plain = true })
    result = {
      lines = #fallback > 0 and fallback or { "" },
      warnings = { "could not render: " .. tostring(result) },
    }
  end

  set_preview_lines(st.pbuf, result.lines)
  st.last_width = width
  -- Kept for inspection; a half-typed document is full of warnings and
  -- showing them on every keystroke is not helpful.
  st.warnings = result.warnings

  if cfg.preview.mode ~= "split" and st.win and api.nvim_win_is_valid(st.win) then
    local height = math.max(1, math.min(#result.lines, editor_rows() - 4))
    local geom = float_geometry(width, height)
    pcall(api.nvim_win_set_config, st.win, geom)
  end

  return result
end

local function schedule_refresh(bufnr)
  local st = sessions[bufnr]
  if not st then
    return
  end
  local delay = config().preview.debounce or 80
  if not st.timer then
    st.timer = uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      M.refresh(bufnr)
    end)
  )
end

local function bind_keys(bufnr, pbuf, st)
  local pcfg = config().preview
  for _, key in ipairs(pcfg.close_keys or { "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      M.close(bufnr)
    end, { buffer = pbuf, nowait = true, silent = true, desc = "Close textlayout preview" })
  end
  vim.keymap.set("n", "r", function()
    M.refresh(bufnr)
  end, { buffer = pbuf, silent = true, desc = "Refresh textlayout preview" })
  vim.keymap.set("n", "s", function()
    -- hop back to the document without closing the preview
    local src_win = st.src_win
    if src_win and api.nvim_win_is_valid(src_win) then
      api.nvim_set_current_win(src_win)
    end
  end, { buffer = pbuf, silent = true, desc = "Switch back to the document" })
end

local function attach(bufnr, st)
  local cfg = config()
  local augroup = api.nvim_create_augroup("textlayout:" .. bufnr, { clear = true })
  st.augroup = augroup

  api.nvim_create_autocmd(cfg.preview.refresh_on or { "TextChanged", "BufWritePost" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      schedule_refresh(bufnr)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      schedule_refresh(bufnr)
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.close(bufnr)
    end,
  })
  if st.win then
    api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(st.win),
      once = true,
      callback = function()
        M.close(bufnr)
      end,
    })
  end
end

--- Open the preview pane for `bufnr`.
--
-- opts.enter  move the cursor into the preview (default: `preview.enter`)
--
-- @return win, pbuf
function M.open(bufnr, opts)
  bufnr = resolve(bufnr)
  opts = opts or {}
  local cfg = config()
  local enter = opts.enter
  if enter == nil then
    enter = cfg.preview.enter == true
  end

  local existing = sessions[bufnr]
  if existing and existing.win and api.nvim_win_is_valid(existing.win) then
    M.refresh(bufnr)
    if enter then
      api.nvim_set_current_win(existing.win)
    end
    return existing.win, existing.pbuf
  end

  local pcfg = cfg.preview
  local src = source_text(bufnr)
  local src_win = api.nvim_get_current_win()

  local pbuf = api.nvim_create_buf(false, true)
  apply_buffer_options(pbuf)
  session.mark(pbuf, api.nvim_buf_get_name(bufnr))

  local win
  if pcfg.mode == "split" then
    local prev = api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, pbuf)
    api.nvim_win_set_width(win, pcfg.width or math.max(20, math.floor(editor_cols() / 2)))
    if not enter then
      api.nvim_set_current_win(prev)
    end
  else
    local width = float_width(pcfg)
    local probe = textlayout.render(src, { width = width, env = meta.new_env(cfg.env) })
    local height = math.max(1, math.min(#probe.lines, editor_rows() - 4))
    local geom = float_geometry(width, height)
    geom.style = "minimal"
    geom.border = pcfg.border or "rounded"
    geom.zindex = 50
    if pcfg.title then
      geom.title = pcfg.title
      geom.title_pos = "center"
    end
    win = api.nvim_open_win(pbuf, enter, geom)
  end

  local st = { bufnr = bufnr, pbuf = pbuf, win = win, src_win = src_win }
  sessions[bufnr] = st
  by_preview[pbuf] = bufnr

  apply_window_options(win)
  bind_keys(bufnr, pbuf, st)
  attach(bufnr, st)
  M.refresh(bufnr)
  return win, pbuf
end

--- Take over `win` as the preview pane for `src`, as when a session that was
-- saved with the pane open is loaded.  Documents that are rendered in place
-- are put back by the inline module instead.
--
-- @return true when the window is showing the preview again
function M.restore_window(win, src)
  if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(src) then
    return false
  end
  if require("textlayout.inline").handles(src) then
    return false
  end
  local existing = sessions[src]
  if existing and existing.win and api.nvim_win_is_valid(existing.win) then
    return false
  end

  local pbuf = api.nvim_create_buf(false, true)
  apply_buffer_options(pbuf)
  session.mark(pbuf, api.nvim_buf_get_name(src))
  api.nvim_win_set_buf(win, pbuf)

  local src_win
  for _, other in ipairs(vim.fn.win_findbuf(src)) do
    if other ~= win then
      src_win = other
    end
  end

  local st = { bufnr = src, pbuf = pbuf, win = win, src_win = src_win }
  sessions[src] = st
  by_preview[pbuf] = src
  apply_window_options(win)
  bind_keys(src, pbuf, st)
  attach(src, st)
  M.refresh(src)
  return true
end

--- Open the preview if needed and move the cursor into it.
function M.focus(bufnr)
  bufnr = resolve(bufnr)
  M.open(bufnr, { enter = true })
  local st = sessions[bufnr]
  if st and st.win and api.nvim_win_is_valid(st.win) then
    api.nvim_set_current_win(st.win)
    return st.win
  end
  return nil
end

--- Move the cursor back to the document that the preview belongs to.
function M.unfocus(bufnr)
  bufnr = resolve(bufnr)
  local st = sessions[bufnr]
  if st and st.src_win and api.nvim_win_is_valid(st.src_win) then
    api.nvim_set_current_win(st.src_win)
    return st.src_win
  end
  return nil
end

--- Close the preview for `bufnr`.
function M.close(bufnr)
  bufnr = resolve(bufnr)
  local st = sessions[bufnr]
  if not st then
    return
  end
  sessions[bufnr] = nil
  if st.pbuf then
    by_preview[st.pbuf] = nil
  end

  if st.timer then
    pcall(function()
      st.timer:stop()
      st.timer:close()
    end)
    st.timer = nil
  end
  if st.augroup then
    pcall(api.nvim_del_augroup_by_id, st.augroup)
    st.augroup = nil
  end
  if st.win and api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
  if st.pbuf and api.nvim_buf_is_valid(st.pbuf) then
    pcall(api.nvim_buf_delete, st.pbuf, { force = true })
  end
end

--- Toggle the preview for `bufnr`.
function M.toggle(bufnr)
  bufnr = resolve(bufnr)
  if M.is_open(bufnr) then
    M.close(bufnr)
  else
    M.open(bufnr)
  end
end

--- The preview window for `bufnr`, or nil.
function M.win_for(bufnr)
  bufnr = resolve(bufnr)
  local st = sessions[bufnr]
  if st and st.win and api.nvim_win_is_valid(st.win) then
    return st.win
  end
  return nil
end

--- The preview buffer for `bufnr`, or nil.
function M.buf_for(bufnr)
  bufnr = resolve(bufnr)
  local st = sessions[bufnr]
  if st and api.nvim_buf_is_valid(st.pbuf) then
    return st.pbuf
  end
  return nil
end

function M.is_open(bufnr)
  bufnr = resolve(bufnr)
  return M.win_for(bufnr) ~= nil
end

--- Write the unshrunk render of `bufnr` into a new scratch buffer.
function M.export(bufnr)
  bufnr = resolve(bufnr)
  local cfg = config()
  local result = textlayout.render_natural(source_text(bufnr), {
    env = meta.new_env(cfg.env),
  })

  vim.cmd("botright new")
  local out = api.nvim_get_current_buf()
  vim.bo[out].buftype = "nofile"
  vim.bo[out].bufhidden = "wipe"
  vim.bo[out].swapfile = false
  vim.bo[out].filetype = "textlayout-preview"
  vim.bo[out].modifiable = true
  api.nvim_buf_set_lines(out, 0, -1, false, #result.lines > 0 and result.lines or { "" })
  vim.bo[out].modifiable = false
  -- An explicit command, so it is fair to say what went wrong.
  for _, warning in ipairs(result.warnings) do
    vim.notify("textlayout: " .. warning, vim.log.levels.WARN)
  end
  return out
end

--- Drop every preview and every variable defined so far.
function M.reset()
  for bufnr in pairs(sessions) do
    M.close(bufnr)
  end
  local cfg = config()
  for key in pairs(cfg.env) do
    cfg.env[key] = nil
  end
end

--- Close everything (used on VimLeavePre).
function M.close_all()
  for bufnr in pairs(sessions) do
    M.close(bufnr)
  end
end

return M
