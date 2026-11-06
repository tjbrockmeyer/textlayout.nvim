-- lua/textlayout/session.lua
-- Keeping previews out of the way of `:mksession`, and putting them back when
-- a session is loaded.
--
-- A preview lives in a scratch buffer, so a session must never record it as if
-- it were a document.  Preview buffers are therefore named with a private
-- scheme -- `textlayout://<the document>` -- and that name is all a loaded
-- session needs to be repaired: the window gets its real document back, and
-- the preview that was on screen when the session was written is opened again.
-- A window that was showing the text stays as it is, and when the text and the
-- preview were both open, both come back.
--
-- Nothing has to happen while the session is written: a name is enough.
-- (Neovim does not save floating windows at all, so a floating preview is
-- never part of a session -- see `preview.mode` in textlayout-config.)

local api = vim.api

local M = {}

--- Prefix that marks a preview buffer.
M.scheme = "textlayout://"

--- The document a preview buffer stands for, or nil when `buf` is a document.
function M.source_of(buf)
  if type(buf) ~= "number" or not api.nvim_buf_is_valid(buf) then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name:sub(1, #M.scheme) ~= M.scheme then
    return nil
  end
  local path = name:sub(#M.scheme + 1)
  if path == "" then
    return nil
  end
  return path
end

--- Name a preview buffer after the document it shows, so a session can tell
-- the two apart.  The name is a label only: a preview works without one.
function M.mark(pbuf, path)
  if type(pbuf) ~= "number" or not api.nvim_buf_is_valid(pbuf) then
    return
  end
  if path == nil or path == "" then
    return
  end
  local name = M.scheme .. path
  if vim.fn.bufnr(name) ~= -1 then
    -- Another buffer owns the name: the one a session restored, most likely,
    -- which is on its way out.  Renaming it would only leave a second buffer
    -- behind, so the preview stays unnamed instead.
    return
  end
  pcall(api.nvim_buf_set_name, pbuf, name)
end

--- Load `path` and give it its filetype back, so the preview modules recognise
-- the document they belong to.
local function load_document(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ filename = path, buf = buf })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  return buf
end

--- Put back the previews a session was saved with.
--
-- Every window that a session restored with a preview buffer in it gets its
-- real document back, and the preview that was open at the time is opened
-- again; windows that were showing the text are left alone.
--
-- In-place rendering holds off until the documents are back in their windows
-- (see inline.begin_session_load), so nothing swaps itself in too early; this
-- lets go of that hold once every window is showing a document again.
--
-- @return the number of windows that are showing a preview again
function M.restore()
  local inline = require("textlayout.inline")
  local preview = require("textlayout.preview")

  local pending, stale = {}, {}
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    local path = M.source_of(buf)
    if path then
      pending[win] = path
      stale[buf] = true
    end
  end

  local windows = {}
  for win, path in pairs(pending) do
    local src = load_document(path)
    if src and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_set_buf, win, src)
      windows[win] = src
    end
  end
  for buf in pairs(stale) do
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end

  pcall(inline.end_session_load)

  local repaired = 0
  for win, src in pairs(windows) do
    if api.nvim_win_is_valid(win) then
      if inline.restore_window(win, src) or preview.restore_window(win, src) then
        repaired = repaired + 1
      end
    end
  end
  return repaired
end

--- Drop every preview that is open now, putting the real text back.
function M.close_previews()
  pcall(function()
    require("textlayout.preview").close_all()
  end)
  pcall(function()
    require("textlayout.inline").detach_all()
  end)
end

--- Install the autocommands that keep sessions clean.
function M.setup()
  local group = api.nvim_create_augroup("textlayout-session", { clear = true })
  api.nvim_create_autocmd("SessionLoadPre", {
    group = group,
    desc = "textlayout: close the previews that are open; the session brings its own",
    callback = function()
      M.close_previews()
      -- A session restores the text and the layout both, so nothing may swap
      -- itself in while it is read -- and a preview buffer made now would
      -- collide with the one the session is about to restore.
      pcall(function()
        require("textlayout.inline").begin_session_load()
      end)
    end,
  })
  api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    desc = "textlayout: put back the previews the session was saved with",
    callback = function()
      pcall(M.restore)
      pcall(function()
        require("textlayout.inline").attach_restored()
      end)
    end,
  })
end

return M
