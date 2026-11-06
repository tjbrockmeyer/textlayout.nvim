-- plugin/textlayout.lua
-- Commands and autocommands. Loaded once at startup.

if vim.g.loaded_textlayout == 1 then
  return
end
vim.g.loaded_textlayout = 1

local SUBCOMMANDS = {
  "open",
  "close",
  "toggle",
  "refresh",
  "focus",
  "unfocus",
  "export",
  "reset",
  "inline",
  "raw",
  "split",
  "swap",
  "status",
}

local function preview()
  return require("textlayout.preview")
end

local function inline()
  return require("textlayout.inline")
end

local function run(sub)
  sub = sub ~= "" and sub or "toggle"
  if sub == "open" then
    preview().open()
  elseif sub == "close" then
    preview().close()
  elseif sub == "toggle" then
    preview().toggle()
  elseif sub == "refresh" then
    preview().refresh()
  elseif sub == "focus" then
    preview().focus()
  elseif sub == "unfocus" then
    preview().unfocus()
  elseif sub == "export" then
    preview().export()
  elseif sub == "reset" then
    preview().reset()
  elseif sub == "inline" then
    inline().open()
  elseif sub == "raw" then
    inline().close()
  elseif sub == "split" then
    inline().split()
  elseif sub == "swap" then
    inline().toggle()
  elseif sub == "status" then
    local status = inline().arrangement()
    local warnings = inline().warnings()
    if #warnings > 0 then
      status = status .. "  (" .. #warnings .. " warning(s), first: " .. warnings[1] .. ")"
    end
    vim.notify("textlayout: " .. status, vim.log.levels.INFO)
  else
    vim.notify("textlayout: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_user_command("TextLayout", function(args)
  run(args.args)
end, {
  nargs = "?",
  complete = function()
    return SUBCOMMANDS
  end,
  desc = "textlayout: preview a layout (open/toggle/inline/raw/export/...)",
})

vim.api.nvim_create_user_command("TextLayoutExport", function()
  preview().export()
end, { desc = "textlayout: render at natural width into a scratch buffer" })

local group = vim.api.nvim_create_augroup("textlayout-global", { clear = true })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    pcall(function()
      preview().close_all()
    end)
  end,
})

-- A preview is a scratch buffer, so a session has to be told which windows were
-- showing a layout; see lua/textlayout/session.lua.
pcall(function()
  require("textlayout.session").setup()
end)
