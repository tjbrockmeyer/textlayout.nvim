-- lua/textlayout/text.lua
-- Display-width aware string helpers.
--
-- The layout engine works in *display columns*, not bytes, so every string
-- helper here decodes UTF-8 and accounts for wide (CJK) and zero-width
-- (combining) characters.  When running inside Neovim we defer to
-- `strdisplaywidth()` so the plugin agrees with what the terminal shows;
-- otherwise a small built-in table is used so the core stays testable
-- outside of Neovim.

local M = {}

local has_vim = type(vim) == "table" and type(vim.fn) == "table"
local vim_strdisplaywidth = has_vim and vim.fn.strdisplaywidth or nil

--- Decode the UTF-8 codepoint starting at byte index `i`.
-- @return codepoint, next_byte_index
local function decode(s, i)
  local b = string.byte(s, i)
  if not b then
    return nil, nil
  end
  if b < 0x80 then
    return b, i + 1
  end
  local n, cp
  if b >= 0xF0 then
    n, cp = 4, b - 0xF0
  elseif b >= 0xE0 then
    n, cp = 3, b - 0xE0
  elseif b >= 0xC0 then
    n, cp = 2, b - 0xC0
  else
    return 0xFFFD, i + 1
  end
  for k = 1, n - 1 do
    local nb = string.byte(s, i + k)
    if not nb or nb < 0x80 or nb > 0xBF then
      return 0xFFFD, i + 1
    end
    cp = cp * 64 + (nb - 0x80)
  end
  return cp, i + n
end

local function is_zero_width(cp)
  return (cp >= 0x0300 and cp <= 0x036F)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
    or cp == 0x200B
    or cp == 0x200C
    or cp == 0x200D
    or cp == 0xFEFF
end

local function is_wide(cp)
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0x303E)
    or (cp >= 0x3041 and cp <= 0x33FF)
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xA000 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
end

--- Width in display columns of a single codepoint.
function M.charwidth(cp)
  if is_zero_width(cp) then
    return 0
  end
  if is_wide(cp) then
    return 2
  end
  return 1
end

--- Display width of `s`.
function M.dwidth(s)
  s = s or ""
  if s == "" then
    return 0
  end
  if vim_strdisplaywidth then
    local ok, w = pcall(vim_strdisplaywidth, s)
    if ok and type(w) == "number" then
      return w
    end
  end
  local w, i = 0, 1
  while true do
    local cp, ni = decode(s, i)
    if not cp then
      break
    end
    w = w + M.charwidth(cp)
    i = ni
  end
  return w
end

--- Hard-clip `s` to at most `w` display columns (never emits a partial char).
function M.clip(s, w)
  s = s or ""
  if w <= 0 then
    return ""
  end
  if M.dwidth(s) <= w then
    return s
  end
  local i, used = 1, 0
  while true do
    local cp, ni = decode(s, i)
    if not cp then
      break
    end
    local cw = M.charwidth(cp)
    if used + cw > w then
      break
    end
    used = used + cw
    i = ni
  end
  return string.sub(s, 1, i - 1)
end

--- Clip `s` to at most `w` display columns, appending `ell` when it had to cut.
-- The result never exceeds `w` columns; it is *not* padded.
function M.truncate(s, w, ell)
  s = s or ""
  if w <= 0 then
    return ""
  end
  if M.dwidth(s) <= w then
    return s
  end
  ell = ell or "\226\128\166" -- U+2026 HORIZONTAL ELLIPSIS
  local ew = M.dwidth(ell)
  local budget = w - ew
  if budget < 1 then
    return M.clip(s, w)
  end
  local out, i, used = {}, 1, 0
  while true do
    local cp, ni = decode(s, i)
    if not cp then
      break
    end
    local cw = M.charwidth(cp)
    if used + cw > budget then
      break
    end
    out[#out + 1] = string.sub(s, i, ni - 1)
    used = used + cw
    i = ni
  end
  return table.concat(out) .. ell
end

--- Right-pad `s` with spaces so it occupies exactly `w` display columns.
function M.pad_right(s, w)
  s = s or ""
  local d = w - M.dwidth(s)
  if d > 0 then
    return s .. string.rep(" ", d)
  end
  return s
end

--- Left-pad `s` with spaces so it occupies exactly `w` display columns.
function M.pad_left(s, w)
  s = s or ""
  local d = w - M.dwidth(s)
  if d > 0 then
    return string.rep(" ", d) .. s
  end
  return s
end

--- Center `s` inside `w` display columns.
function M.center(s, w)
  s = s or ""
  local d = w - M.dwidth(s)
  if d <= 0 then
    return s
  end
  local left = math.floor(d / 2)
  return string.rep(" ", left) .. s .. string.rep(" ", d - left)
end

--- Split `s` into a list of single-character strings.
function M.chars(s)
  local out, i = {}, 1
  while true do
    local cp, ni = decode(s, i)
    if not cp then
      break
    end
    out[#out + 1] = string.sub(s, i, ni - 1)
    i = ni
  end
  return out
end

--- Word-wrap `s` into lines of at most `w` display columns. Words wider than
-- `w` on their own are hard-broken rather than overflowing.
function M.wrap(s, w)
  s = s or ""
  if w <= 0 then
    return { "" }
  end
  if M.dwidth(s) <= w then
    return { s }
  end
  local out = {}
  local line = ""
  for word in string.gmatch(s, "%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if M.dwidth(candidate) <= w then
      line = candidate
    else
      if line ~= "" then
        out[#out + 1] = line
        line = ""
      end
      while M.dwidth(word) > w do
        local head = M.clip(word, w)
        out[#out + 1] = head
        word = string.sub(word, #head + 1)
      end
      line = word
    end
  end
  out[#out + 1] = line
  return out
end

return M
