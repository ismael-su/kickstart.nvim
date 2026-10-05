--- iTerm2 inline-image backend (OSC 1337 `File=`).
---
--- iTerm2 decodes PNG/JPEG/GIF/WebP itself, so an image needs no server-side
--- tooling: read the bytes, base64 them, state the size in cells.
---
--- Unlike the Kitty protocol there are no placement ids and no delete command:
--- the image is drawn into the grid as content. Erasing it therefore means
--- making Neovim repaint those cells, which is what `clear()` does.
local terminal = require 'inlineview.terminal'
local util = require 'inlineview.util'

local M = {}

M.name = 'iterm2'

function M.available() return terminal.has_writer() end

--- iTerm2 handles every format we care about natively.
function M.supports_path() return true end

---@param spec {path: string, row: integer, col: integer, cols: integer, rows: integer}
---@return boolean ok, string|nil err
function M.draw(spec)
  local data, err = util.read_file(spec.path)
  if not data then return false, err or 'read failed' end

  local rows = spec.rows
  -- An image that reaches the bottom row makes the terminal scroll, which
  -- shifts Neovim's screen out from under it. Keep one row in hand.
  local last_safe = vim.o.lines - 1
  if spec.row + rows - 1 > last_safe then rows = last_safe - spec.row + 1 end
  if rows < 1 or spec.cols < 1 then return false, 'no room to draw' end

  local args = table.concat({
    'inline=1',
    'size=' .. #data,
    'name=' .. vim.base64.encode(vim.fn.fnamemodify(spec.path, ':t')),
    'width=' .. spec.cols,
    'height=' .. rows,
    'preserveAspectRatio=1',
    -- Harmless on versions that ignore it; DECSC/DECRC is the real guarantee.
    'doNotMoveCursor=1',
  }, ';')

  local seq = table.concat {
    terminal.ESC,
    ']1337;File=',
    args,
    ':',
    vim.base64.encode(data),
    terminal.BEL,
  }

  terminal.write_at(spec.row, spec.col, seq)
  return true
end

--- There is no targeted erase in this protocol; force a full repaint instead.
function M.clear()
  vim.schedule(function() pcall(vim.cmd, 'redraw!') end)
end

M.clear_all = M.clear

return M
