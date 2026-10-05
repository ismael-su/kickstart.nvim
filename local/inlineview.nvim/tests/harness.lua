--- A very small test harness.
---
--- Deliberately dependency-free: the suite must run with nothing but the
--- Neovim binary, so CI and a fresh clone behave identically.
local M = {
  passed = 0,
  failed = 0,
  failures = {},
  stack = {},
}

local function path() return table.concat(M.stack, ' › ') end

local GREEN, RED, DIM, BOLD, RESET = '\27[32m', '\27[31m', '\27[90m', '\27[1m', '\27[0m'

function M.describe(name, fn)
  M.stack[#M.stack + 1] = name
  io.stdout:write(('\n%s%s%s\n'):format(BOLD, name, RESET))
  local ok, err = pcall(fn)
  if not ok then
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = { name = path() .. ' (suite)', err = err }
    io.stdout:write(('  %s✗ suite raised: %s%s\n'):format(RED, tostring(err), RESET))
  end
  table.remove(M.stack)
end

function M.it(name, fn)
  M.stack[#M.stack + 1] = name
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
    io.stdout:write(('  %s✓%s %s\n'):format(GREEN, RESET, name))
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = { name = path(), err = err }
    io.stdout:write(('  %s✗ %s%s\n      %s%s%s\n'):format(RED, name, RESET, DIM, tostring(err), RESET))
  end
  table.remove(M.stack)
end

local function render(v)
  if type(v) == 'table' then return vim.inspect(v) end
  return tostring(v)
end

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', render(expected), render(actual)), 2) end
end

function M.ne(unexpected, actual, msg)
  if vim.deep_equal(unexpected, actual) then error(('%sexpected something other than %s'):format(msg and (msg .. ': ') or '', render(unexpected)), 2) end
end

function M.ok(value, msg)
  if not value then error(msg or 'expected a truthy value, got ' .. render(value), 2) end
end

function M.falsy(value, msg)
  if value then error(msg or 'expected a falsy value, got ' .. render(value), 2) end
end

--- Numeric comparison with a tolerance, for anything involving rounding.
function M.near(expected, actual, tolerance, msg)
  tolerance = tolerance or 1
  if type(actual) ~= 'number' or math.abs(expected - actual) > tolerance then
    error(('%sexpected %s ± %s, got %s'):format(msg and (msg .. ': ') or '', expected, tolerance, render(actual)), 2)
  end
end

function M.contains(haystack, needle, msg)
  if type(haystack) ~= 'string' or not haystack:find(needle, 1, true) then
    error(('%sexpected to find %q in %q'):format(msg and (msg .. ': ') or '', needle, tostring(haystack)), 2)
  end
end

function M.not_contains(haystack, needle, msg)
  if type(haystack) == 'string' and haystack:find(needle, 1, true) then
    error(('%sdid not expect to find %q in %q'):format(msg and (msg .. ': ') or '', needle, haystack), 2)
  end
end

function M.matches(haystack, pattern, msg)
  if type(haystack) ~= 'string' or not haystack:match(pattern) then
    error(('%sexpected %q to match %q'):format(msg and (msg .. ': ') or '', tostring(haystack), pattern), 2)
  end
end

function M.throws(fn, msg)
  local ok = pcall(fn)
  if ok then error(msg or 'expected the call to raise', 2) end
end

function M.summary()
  local total = M.passed + M.failed
  io.stdout:write(('\n%s%s%s\n'):format(BOLD, ('─'):rep(52), RESET))
  if M.failed == 0 then
    io.stdout:write(('%s%d passed%s, 0 failed (%d assertions run)\n'):format(GREEN, M.passed, RESET, total))
  else
    io.stdout:write(('%s%d failed%s, %d passed\n\n'):format(RED, M.failed, RESET, M.passed))
    for _, f in ipairs(M.failures) do
      io.stdout:write(('  %s%s%s\n    %s\n'):format(RED, f.name, RESET, tostring(f.err)))
    end
  end
  return M.failed == 0
end

return M
