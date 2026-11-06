-- lua/textlayout/util.lua
-- Small dependency-free helpers shared by the textlayout modules.

local M = {}

--- Deep copy a value. Tables with metatables keep them.
function M.deepcopy(v, seen)
  if type(v) ~= "table" then
    return v
  end
  seen = seen or {}
  if seen[v] then
    return seen[v]
  end
  local out = {}
  seen[v] = out
  for k, val in pairs(v) do
    out[M.deepcopy(k, seen)] = M.deepcopy(val, seen)
  end
  return setmetatable(out, getmetatable(v))
end

--- Recursively merge `override` into a deep copy of `base`.
function M.merge(base, override)
  local out = M.deepcopy(base)
  if type(override) ~= "table" then
    return out
  end
  for k, v in pairs(override) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = M.merge(out[k], v)
    else
      out[k] = M.deepcopy(v)
    end
  end
  return out
end

function M.clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

--- `ipairs`-style map that keeps order.
function M.map(list, fn)
  local out = {}
  for i = 1, #list do
    out[i] = fn(list[i], i)
  end
  return out
end

function M.shallow_copy(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
end

return M
