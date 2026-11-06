-- ftdetect/textlayout.lua
vim.filetype.add({
  extension = {
    tl = "textlayout",
    tlayout = "textlayout",
    -- `.tlmd` renders in place: NORMAL mode shows the preview, every other
    -- mode shows the real text.
    tlmd = "tlmd",
  },
  filename = {
    [".textlayout"] = "textlayout",
  },
})
