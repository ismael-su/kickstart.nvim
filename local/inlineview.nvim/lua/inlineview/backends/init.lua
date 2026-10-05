--- Backend dispatcher: resolves the detected protocol to an implementation and
--- degrades gracefully when the chosen one cannot handle a given file.
local terminal = require 'inlineview.terminal'

local M = {}

local registry = {
  iterm2 = 'inlineview.backends.iterm2',
  kitty = 'inlineview.backends.kitty',
  blocks = 'inlineview.backends.blocks',
}

---@param name string
---@return table|nil
function M.get(name)
  local mod = registry[name]
  if not mod then return nil end
  local ok, backend = pcall(require, mod)
  return ok and backend or nil
end

--- The backend to use for `path`.
---
--- Kitty only decodes PNG, so a JPEG under Ghostty quietly lands on the blocks
--- backend rather than failing.
---@param path string|nil
---@return table|nil backend, string|nil err
function M.resolve(path)
  local name = terminal.backend_name()
  if name == 'none' then return nil, 'no supported image protocol detected (see :checkhealth inlineview)' end

  local backend = M.get(name)
  if not backend then return nil, 'unknown backend: ' .. tostring(name) end
  if not backend.available() then return nil, ('backend %q is unavailable'):format(name) end

  if path and not backend.supports_path(path) then
    local fallback = M.get 'blocks'
    if fallback and fallback.available() then return fallback end
    return nil, ('backend %q cannot display %s'):format(name, vim.fn.fnamemodify(path, ':t'))
  end

  return backend
end

--- Erase everything every backend may have drawn.
function M.clear_all()
  for name in pairs(registry) do
    local backend = M.get(name)
    if backend and backend.clear_all then pcall(backend.clear_all) end
  end
end

return M
