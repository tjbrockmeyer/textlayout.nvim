-- ftplugin/tlmd.lua
-- `.tlmd` files are shown laid out.  Nothing switches by itself: press the
-- toggle key (`<leader>tp` by default, see `inline.toggle_key`) in NORMAL mode
-- to swap the current window between the preview and the real text, keeping
-- the cursor on the same line.  The preview buffer is never modifiable.
--
-- Turn it off for the whole session with
--     require("textlayout").setup({ inline = { enabled = false } })
-- or per window with `:TextLayout raw` / `:TextLayout inline` / `:TextLayout swap`.

require("textlayout.inline").attach()
