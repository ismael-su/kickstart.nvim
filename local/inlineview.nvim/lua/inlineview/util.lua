--- Small shared helpers. No side effects on require.
local M = {}

--- FNV-1a over a string, returned as 8 lowercase hex chars.
--- Used for cache keys, so it only needs to be stable and cheap.
---@param s string
---@return string
function M.hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    h = bit.band(h * 16777619, 0xFFFFFFFF)
  end
  return string.format('%08x', h)
end

--- Read a whole file as a binary string.
---@param path string
---@return string|nil content, string|nil err
function M.read_file(path)
  local fd, err = vim.uv.fs_open(path, 'r', 438)
  if not fd then return nil, err end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil, 'cannot stat ' .. path
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data
end

---@param path string
---@return boolean
function M.exists(path) return vim.uv.fs_stat(path) ~= nil end

--- Modification time as an integer, or 0 when the file is gone.
---@param path string
---@return integer
function M.mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec or 0
end

--- Trailing-edge debounce. The returned function restarts the timer on every
--- call; `fn` runs once the calls stop for `ms`. Scheduled so callers are free
--- to touch the API from any context.
---@param ms integer
---@param fn fun(...)
---@return fun(...)
function M.debounce(ms, fn)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end
    timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      vim.schedule(function() fn(unpack(args)) end)
    end)
  end
end

---@param msg string
---@param level integer|nil
function M.notify(msg, level) vim.notify('[inlineview] ' .. msg, level or vim.log.levels.INFO) end

---@param msg string
function M.warn(msg) M.notify(msg, vim.log.levels.WARN) end

---@param msg string
function M.err(msg) M.notify(msg, vim.log.levels.ERROR) end

--- Directory used for rasterized PDF pages and scaled images.
---@return string
function M.cache_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath 'cache', 'inlineview')
  vim.fn.mkdir(dir, 'p')
  return dir
end

---@param n number
---@param lo number
---@param hi number
---@return number
function M.clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

return M
