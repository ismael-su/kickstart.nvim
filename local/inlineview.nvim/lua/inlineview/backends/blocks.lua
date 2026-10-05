--- Unicode half-block backend, via chafa.
---
--- The universal fallback: the output is ordinary coloured text, so it works
--- on any truecolor terminal with no graphics protocol at all. Resolution is
--- two pixels per cell vertically, which is coarse but legible.
local terminal = require 'inlineview.terminal'

local M = {}

M.name = 'blocks'

function M.available() return terminal.has_writer() and vim.fn.executable 'chafa' == 1 end

function M.supports_path() return true end

--- chafa reads most formats, so cache per (path, size, mtime) and reuse.
local cache = {}

---@param path string
---@param cols integer
---@param rows integer
---@return string[]|nil lines, string|nil err
local function render(path, cols, rows)
  local key = table.concat({ path, cols, rows, require('inlineview.util').mtime(path) }, ':')
  if cache[key] then return cache[key] end

  local res = vim
    .system({
      'chafa',
      '-f',
      'symbols',
      '--symbols',
      'block+space+half',
      '-s',
      string.format('%dx%d', cols, rows),
      '--animate',
      'off',
      '--polite',
      'on',
      '--',
      path,
    }, { text = true })
    :wait(10000)

  if res.code ~= 0 then return nil, (res.stderr or 'chafa failed'):gsub('%s+$', '') end

  local lines = {}
  for line in (res.stdout or ''):gmatch '([^\n]*)\n?' do
    if line ~= '' then lines[#lines + 1] = line end
  end
  if #lines == 0 then return nil, 'chafa produced no output' end

  cache[key] = lines
  return lines
end

---@param spec {path: string, row: integer, col: integer, cols: integer, rows: integer}
---@return boolean ok, string|nil err
function M.draw(spec)
  local lines, err = render(spec.path, spec.cols, spec.rows)
  if not lines then return false, err end

  -- Each row is positioned absolutely; chafa's own newlines would scroll the
  -- screen and desynchronise Neovim's view.
  local parts = {}
  local last_safe = vim.o.lines - 1
  for i, line in ipairs(lines) do
    local row = spec.row + i - 1
    if row > last_safe then break end
    parts[#parts + 1] = string.format('%s[%d;%dH%s', terminal.ESC, row, spec.col, line)
  end

  if #parts == 0 then return false, 'no room to draw' end

  -- SGR reset so the colours do not bleed into Neovim's own drawing.
  terminal.write(table.concat { terminal.ESC, '7', table.concat(parts), terminal.ESC, '[0m', terminal.ESC, '8' })
  return true
end

function M.clear()
  vim.schedule(function() pcall(vim.cmd, 'redraw!') end)
end

M.clear_all = M.clear

function M.invalidate() cache = {} end

return M
