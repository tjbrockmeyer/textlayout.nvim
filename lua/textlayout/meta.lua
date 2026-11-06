-- lua/textlayout/meta.lua
-- Meta-text: the little expression language that lives inside `{ ... }`.
--
--   {1+1}                      -> 2
--   {"hello "+"world"}         -> hello world
--   {DEXTERITY=14}             -> (defines a variable, renders nothing)
--   {DEX=floor((DEXTERITY-10)/2)}
--   {DEX+PROF+1}               -> display
--
-- Statements are separated by `;` and the value of the last statement is what
-- gets rendered, so `{X=1; X*2}` renders `2`.

local text = require("textlayout.text")

local M = {}

local KEYWORDS = {
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["true"] = true,
  ["false"] = true,
  ["nil"] = true,
}

local function is_digit(c)
  return c >= "0" and c <= "9"
end

local function is_alpha(c)
  return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end

local function is_alnum(c)
  return is_alpha(c) or is_digit(c)
end

local function truthy(v)
  return v ~= nil and v ~= false
end

--- Numbers print as integers when they are integral, otherwise with enough
-- significant digits to be useful but without float noise (0.1+0.2 -> 0.3).
local function fmt_num(v)
  if v ~= v then
    return "nan"
  end
  if v == math.huge then
    return "inf"
  end
  if v == -math.huge then
    return "-inf"
  end
  if v == math.floor(v) and math.abs(v) < 1e15 then
    return string.format("%d", v)
  end
  return (string.format("%.14g", v))
end

--- Render any value as display text.
function M.fmt(v)
  local t = type(v)
  if t == "number" then
    return fmt_num(v)
  elseif t == "string" then
    return v
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "nil" then
    return ""
  end
  return tostring(v)
end

local function tonum(v)
  if type(v) == "number" then
    return v
  end
  if type(v) == "string" then
    return tonumber(v)
  end
  return nil
end

----------------------------------------------------------------------
-- Tokenizer
----------------------------------------------------------------------

local STRING_ESCAPES = {
  n = "\n",
  t = "\t",
  r = "\r",
  ["\\"] = "\\",
  ['"'] = '"',
  ["'"] = "'",
  ["{"] = "{",
  ["}"] = "}",
}

local OPERATOR_CHARS = "+-*/%^()<>=,;"

local function tokenize(src)
  local toks = {}
  local i, n = 1, #src
  while i <= n do
    local c = string.sub(src, i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    elseif is_digit(c) or (c == "." and is_digit(string.sub(src, i + 1, i + 1))) then
      local j = i
      while j <= n do
        local d = string.sub(src, j, j)
        if is_digit(d) or d == "." then
          j = j + 1
        else
          break
        end
      end
      local e = string.sub(src, j, j)
      if e == "e" or e == "E" then
        local k = j + 1
        local sign = string.sub(src, k, k)
        if sign == "+" or sign == "-" then
          k = k + 1
        end
        if is_digit(string.sub(src, k, k)) then
          while k <= n and is_digit(string.sub(src, k, k)) do
            k = k + 1
          end
          j = k
        end
      end
      local num = tonumber(string.sub(src, i, j - 1))
      if not num then
        return nil, "malformed number near '" .. string.sub(src, i, j - 1) .. "'"
      end
      toks[#toks + 1] = { t = "num", v = num, pos = i }
      i = j
    elseif is_alpha(c) then
      local j = i
      while j <= n and is_alnum(string.sub(src, j, j)) do
        j = j + 1
      end
      local word = string.sub(src, i, j - 1)
      toks[#toks + 1] = { t = KEYWORDS[word] and "kw" or "id", v = word, pos = i }
      i = j
    elseif c == '"' or c == "'" then
      local quote = c
      local j = i + 1
      local buf = {}
      local closed = false
      while j <= n do
        local d = string.sub(src, j, j)
        if d == "\\" then
          local e = string.sub(src, j + 1, j + 1)
          buf[#buf + 1] = STRING_ESCAPES[e] or e
          j = j + 2
        elseif d == quote then
          closed = true
          j = j + 1
          break
        else
          buf[#buf + 1] = d
          j = j + 1
        end
      end
      if not closed then
        return nil, "unterminated string"
      end
      toks[#toks + 1] = { t = "str", v = table.concat(buf), pos = i }
      i = j
    else
      local two = string.sub(src, i, i + 1)
      if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
        toks[#toks + 1] = { t = "op", v = two, pos = i }
        i = i + 2
      elseif string.find(OPERATOR_CHARS, c, 1, true) then
        toks[#toks + 1] = { t = "op", v = c, pos = i }
        i = i + 1
      else
        return nil, "unexpected character '" .. c .. "'"
      end
    end
  end
  toks[#toks + 1] = { t = "eof", pos = n + 1 }
  return toks
end

----------------------------------------------------------------------
-- Built-in functions
----------------------------------------------------------------------

local builtins = {}

local function require_num(v, fn)
  local n = tonum(v)
  if not n then
    error(fn .. "() expects a number, got " .. type(v), 0)
  end
  return n
end

builtins.floor = function(x)
  return math.floor(require_num(x, "floor"))
end
builtins.ceil = function(x)
  return math.ceil(require_num(x, "ceil"))
end
builtins.round = function(x)
  local n = require_num(x, "round")
  return math.floor(n + (n >= 0 and 0.5 or -0.5))
end
builtins.abs = function(x)
  return math.abs(require_num(x, "abs"))
end
builtins.sign = function(x)
  local n = require_num(x, "sign")
  if n > 0 then
    return 1
  elseif n < 0 then
    return -1
  end
  return 0
end
builtins.sqrt = function(x)
  return math.sqrt(require_num(x, "sqrt"))
end
builtins.pow = function(x, y)
  return require_num(x, "pow") ^ require_num(y, "pow")
end
builtins.clamp = function(x, lo, hi)
  local n = require_num(x, "clamp")
  lo, hi = require_num(lo, "clamp"), require_num(hi, "clamp")
  if n < lo then
    return lo
  elseif n > hi then
    return hi
  end
  return n
end
builtins.min = function(...)
  local args = { ... }
  if #args == 0 then
    return nil
  end
  local best = args[1]
  for i = 2, #args do
    if args[i] < best then
      best = args[i]
    end
  end
  return best
end
builtins.max = function(...)
  local args = { ... }
  if #args == 0 then
    return nil
  end
  local best = args[1]
  for i = 2, #args do
    if args[i] > best then
      best = args[i]
    end
  end
  return best
end
builtins.len = function(s)
  return text.dwidth(M.fmt(s))
end
builtins.upper = function(s)
  return string.upper(M.fmt(s))
end
builtins.lower = function(s)
  return string.lower(M.fmt(s))
end
builtins.str = function(v)
  return M.fmt(v)
end
builtins.num = function(v)
  local n = tonum(v)
  if not n then
    error("num() expects something numeric, got " .. type(v), 0)
  end
  return n
end
builtins.ifelse = function(c, a, b)
  if truthy(c) then
    return a
  end
  return b
end
builtins.rep = function(s, n)
  local count = tonum(n) or 1
  if count < 0 then
    count = 0
  end
  return string.rep(M.fmt(s), count)
end
builtins.pad = function(s, n, side)
  local width = tonum(n) or 0
  local str = M.fmt(s)
  if side == "left" or side == "l" then
    return text.pad_left(str, width)
  end
  return text.pad_right(str, width)
end

M.builtins = builtins

----------------------------------------------------------------------
-- Parser / evaluator (single pass, evaluates while parsing)
----------------------------------------------------------------------

local function compare(op, a, b)
  if op == "==" then
    return a == b
  end
  if op == "~=" then
    return a ~= b
  end
  local na, nb = tonum(a), tonum(b)
  if na and nb then
    a, b = na, nb
  elseif not (type(a) == "string" and type(b) == "string") then
    error("cannot compare " .. type(a) .. " and " .. type(b) .. " with '" .. op .. "'", 0)
  end
  if op == "<" then
    return a < b
  elseif op == "<=" then
    return a <= b
  elseif op == ">" then
    return a > b
  end
  return a >= b
end

local function add(op, a, b)
  if op == "+" and (type(a) == "string" or type(b) == "string") then
    return M.fmt(a) .. M.fmt(b)
  end
  local na, nb = tonum(a), tonum(b)
  if not na then
    error("cannot use '" .. op .. "' on " .. type(a), 0)
  end
  if not nb then
    error("cannot use '" .. op .. "' on " .. type(b), 0)
  end
  if op == "+" then
    return na + nb
  end
  return na - nb
end

local function mul(op, a, b)
  local na = tonum(a)
  local nb = tonum(b)
  if not na then
    error("cannot use '" .. op .. "' on " .. type(a), 0)
  end
  if not nb then
    error("cannot use '" .. op .. "' on " .. type(b), 0)
  end
  if op == "*" then
    return na * nb
  elseif op == "/" then
    return na / nb
  end
  return na % nb
end

local function is_op(P, v)
  local t = P.toks[P.i]
  return t.t == "op" and t.v == v
end

local function is_kw(P, v)
  local t = P.toks[P.i]
  return t.t == "kw" and t.v == v
end

local parse_expr

local function parse_primary(P)
  local t = P.toks[P.i]
  if t.t == "num" or t.t == "str" then
    P.i = P.i + 1
    return t.v
  end
  if t.t == "kw" then
    P.i = P.i + 1
    if t.v == "true" then
      return true
    elseif t.v == "false" then
      return false
    elseif t.v == "nil" then
      return nil
    end
    error("unexpected keyword '" .. t.v .. "'", 0)
  end
  if t.t == "id" then
    P.i = P.i + 1
    if is_op(P, "(") then
      P.i = P.i + 1
      local args = {}
      if not is_op(P, ")") then
        while true do
          args[#args + 1] = parse_expr(P)
          if is_op(P, ",") then
            P.i = P.i + 1
          else
            break
          end
        end
      end
      if not is_op(P, ")") then
        error("expected ')' after arguments to " .. t.v .. "()", 0)
      end
      P.i = P.i + 1
      local fn = P.env[t.v]
      if fn == nil then
        fn = builtins[t.v]
      end
      if type(fn) ~= "function" then
        error("'" .. t.v .. "' is not a function", 0)
      end
      return fn(unpack(args))
    end
    local v = P.env[t.v]
    if v == nil then
      if builtins[t.v] ~= nil then
        error("'" .. t.v .. "' is a function; did you mean " .. t.v .. "(...)?", 0)
      end
      error("unknown variable '" .. t.v .. "'", 0)
    end
    return v
  end
  if is_op(P, "(") then
    P.i = P.i + 1
    local v = parse_expr(P)
    if not is_op(P, ")") then
      error("expected ')'", 0)
    end
    P.i = P.i + 1
    return v
  end
  error("unexpected token in expression", 0)
end

local function tonum_checked(v)
  local n = tonum(v)
  if not n then
    error("expected a number, got " .. type(v), 0)
  end
  return n
end

local function parse_unary(P)
  if is_op(P, "-") then
    P.i = P.i + 1
    return -tonum_checked(parse_unary(P))
  end
  if is_op(P, "+") then
    P.i = P.i + 1
    return tonum_checked(parse_unary(P))
  end
  if is_kw(P, "not") then
    P.i = P.i + 1
    return not truthy(parse_unary(P))
  end
  return parse_primary(P)
end


local function parse_pow(P)
  local base = parse_unary(P)
  if is_op(P, "^") then
    P.i = P.i + 1
    return tonum_checked(base) ^ tonum_checked(parse_pow(P))
  end
  return base
end

local function parse_mul(P)
  local v = parse_pow(P)
  while true do
    local t = P.toks[P.i]
    if t.t == "op" and (t.v == "*" or t.v == "/" or t.v == "%") then
      P.i = P.i + 1
      v = mul(t.v, v, parse_pow(P))
    else
      break
    end
  end
  return v
end

local function parse_add(P)
  local v = parse_mul(P)
  while true do
    local t = P.toks[P.i]
    if t.t == "op" and (t.v == "+" or t.v == "-") then
      P.i = P.i + 1
      v = add(t.v, v, parse_mul(P))
    elseif t.t == "op" and t.v == ".." then
      P.i = P.i + 1
      v = M.fmt(v) .. M.fmt(parse_mul(P))
    else
      break
    end
  end
  return v
end

local function parse_cmp(P)
  local v = parse_add(P)
  while true do
    local t = P.toks[P.i]
    if
      t.t == "op"
      and (t.v == "==" or t.v == "~=" or t.v == "<" or t.v == ">" or t.v == "<=" or t.v == ">=")
    then
      P.i = P.i + 1
      v = compare(t.v, v, parse_add(P))
    else
      break
    end
  end
  return v
end

local function parse_and(P)
  local v = parse_cmp(P)
  while is_kw(P, "and") do
    P.i = P.i + 1
    local r = parse_cmp(P)
    if truthy(v) then
      v = r
    end
  end
  return v
end

local function parse_or(P)
  local v = parse_and(P)
  while is_kw(P, "or") do
    P.i = P.i + 1
    local r = parse_and(P)
    if not truthy(v) then
      v = r
    end
  end
  return v
end

parse_expr = parse_or

local function parse_statement(P)
  local t = P.toks[P.i]
  local n = P.toks[P.i + 1]
  if t.t == "id" and n and n.t == "op" and n.v == "=" then
    local name = t.v
    P.i = P.i + 2
    local value = parse_expr(P)
    P.env[name] = value
    return nil
  end
  return parse_expr(P)
end

local function parse_program(P)
  local last = nil
  while P.toks[P.i].t ~= "eof" do
    last = parse_statement(P)
    if is_op(P, ";") then
      P.i = P.i + 1
    else
      break
    end
  end
  return last
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Create an environment table whose lookups fall back to `base`.
function M.new_env(base)
  return setmetatable({}, { __index = base or {} })
end

--- Evaluate the body of a `{ ... }` group.
-- @return value, err
function M.eval(src, env)
  local toks, err = tokenize(src)
  if not toks then
    return nil, err
  end
  local P = { toks = toks, i = 1, env = env or {} }
  local ok, result = pcall(parse_program, P)
  if not ok then
    return nil, tostring(result)
  end
  local t = P.toks[P.i]
  if t.t ~= "eof" then
    return nil, "unexpected '" .. tostring(t.v) .. "'"
  end
  return result, nil
end

--- Evaluate and format the body of a `{ ... }` group.
-- @return string, err
function M.render(src, env)
  local v, err = M.eval(src, env)
  if err then
    return nil, err
  end
  return M.fmt(v), nil
end

return M
