--- Test entry point.
---
---   nvim -l tests/run.lua            run everything
---   nvim -l tests/run.lua geometry   run specs whose name contains "geometry"
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
package.path = root .. '/tests/?.lua;' .. package.path

local h = require 'harness'

-- Fixtures are generated rather than committed, so make a fresh clone work.
if vim.fn.filereadable(root .. '/tests/fixtures/sample.pdf') == 0 then
  io.stdout:write 'generating test fixtures...\n'
  local res = vim.system({ 'python3', root .. '/tests/fixtures/gen.py' }, { text = true }):wait(60000)
  if res.code ~= 0 then
    io.stderr:write('could not generate fixtures: ' .. tostring(res.stderr) .. '\n')
    os.exit(1)
  end
end

-- Expose the harness as globals so specs stay readable.
_G.describe = h.describe
_G.it = h.it
_G.eq = h.eq
_G.ne = h.ne
_G.ok = h.ok
_G.falsy = h.falsy
_G.near = h.near
_G.contains = h.contains
_G.not_contains = h.not_contains
_G.matches = h.matches
_G.throws = h.throws
_G.FIXTURES = root .. '/tests/fixtures'
_G.ROOT = root

--- Make the suite deterministic regardless of the environment it runs in.
---
--- The config module is reconfigured in place rather than reloaded: every
--- other module captures `require('inlineview.config')` at load time, so
--- swapping the module out would leave them reading a stale table.
_G.reset_config = function(opts)
  local config = require 'inlineview.config'
  config.setup(vim.tbl_deep_extend('force', { cell = { width = 10, height = 20 } }, opts or {}))
  return config
end

--- Sentinel for `with_env`, since a Lua table literal cannot hold a nil value
--- -- `{ FOO = nil }` is simply an empty table.
_G.UNSET = setmetatable({}, { __tostring = function() return '<unset>' end })

--- Swap in a capturing writer for the duration of `fn` and return everything
--- that would have gone to the terminal.
---@param fn fun()
---@return string
_G.capture_terminal = function(fn)
  local terminal = require 'inlineview.terminal'
  local chunks = {}
  terminal.set_writer(function(data) chunks[#chunks + 1] = data end)
  local called_ok, err = pcall(fn)
  terminal.set_writer(nil)
  if not called_ok then error(err, 0) end
  return table.concat(chunks)
end

--- Run `fn` with environment variables temporarily replaced, restoring them
--- and dropping cached detection afterwards. Use the `UNSET` sentinel to
--- remove a variable for the duration of the call.
---@param vars table<string, string|table>
---@param fn fun()
_G.with_env = function(vars, fn)
  local terminal = require 'inlineview.terminal'

  local function apply(name, value)
    if value == nil or value == UNSET then
      vim.fn.setenv(name, vim.NIL)
    else
      vim.fn.setenv(name, value)
    end
  end

  local saved = {}
  for k, v in pairs(vars) do
    saved[k] = vim.env[k] == nil and UNSET or vim.env[k]
    apply(k, v)
  end
  terminal.reset()

  local called_ok, err = pcall(fn)

  for k in pairs(vars) do
    apply(k, saved[k])
  end
  terminal.reset()
  if not called_ok then error(err, 0) end
end

local filter = arg and arg[1]

local specs = vim.fn.glob(root .. '/tests/*_spec.lua', false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  local name = vim.fn.fnamemodify(spec, ':t:r')
  if not filter or name:find(filter, 1, true) then dofile(spec) end
end

os.exit(h.summary() and 0 or 1)
