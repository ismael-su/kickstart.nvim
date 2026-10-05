--- Everything that talks to the host terminal: raw writes, multiplexer
--- passthrough, cell geometry and protocol detection.
---
--- Neovim has no idea these bytes exist, so every escape sequence we emit is
--- bracketed with DECSC/DECRC and positioned absolutely. Anything we draw is
--- erased the next time Neovim repaints that cell, which is why callers repaint
--- on scroll/resize rather than assuming persistence.
local util = require 'inlineview.util'

local M = {}

M.ESC = '\27'
M.BEL = '\7'
M.ST = '\27\\'

local writer = nil
local writer_resolved = false

--- Resolve a function that writes raw bytes to the controlling terminal.
--- fd 1 is what the TUI itself draws on; /dev/tty is the fallback for the odd
--- case where stdout has been redirected.
---@return (fun(data: string))|nil
local function resolve_writer()
  local ok, tty = pcall(vim.uv.new_tty, 1, false)
  if ok and tty then
    return function(data) tty:write(data) end
  end
  local fd = vim.uv.fs_open('/dev/tty', 'w', 438)
  if fd then
    return function(data) vim.uv.fs_write(fd, data) end
  end
  return nil
end

--- Override the raw writer. Used by the test suite to capture output, and
--- usable from a config to tee sequences somewhere else.
---@param fn (fun(data: string))|nil
function M.set_writer(fn)
  writer = fn
  writer_resolved = true
end

---@return boolean
function M.has_writer()
  if not writer_resolved then
    writer = resolve_writer()
    writer_resolved = true
  end
  return writer ~= nil
end

--- Wrap a sequence so it survives tmux/screen rather than being eaten by them.
---@param seq string
---@return string
function M.passthrough(seq)
  if vim.env.TMUX and vim.env.TMUX ~= '' then
    -- tmux needs every ESC in the payload doubled.
    return M.ESC .. 'Ptmux;' .. seq:gsub(M.ESC, M.ESC .. M.ESC) .. M.ESC .. '\\'
  end
  if (vim.env.TERM or ''):match '^screen' then
    -- screen's DCS payload is capped, so the sequence is chunked.
    local out = {}
    for i = 1, #seq, 768 do
      out[#out + 1] = M.ESC .. 'P' .. seq:sub(i, i + 767) .. M.ESC .. '\\'
    end
    return table.concat(out)
  end
  return seq
end

--- Write raw bytes to the terminal, applying multiplexer passthrough.
---@param seq string
function M.write(seq)
  if not M.has_writer() then return end
  writer(M.passthrough(seq))
end

--- Write bytes with the cursor parked at (row, col), then put it back.
--- Both coordinates are 1-based screen cells, matching `win_screenpos()`.
---@param row integer
---@param col integer
---@param seq string
function M.write_at(row, col, seq)
  M.write(table.concat {
    M.ESC .. '7', -- DECSC: save cursor + attributes
    string.format('%s[%d;%dH', M.ESC, row, col),
    seq,
    M.ESC .. '8', -- DECRC: restore
  })
end

--------------------------------------------------------------------------
-- Cell geometry
--------------------------------------------------------------------------

local cell_cache = nil

--- Ask the kernel for the window size the terminal reported, including the
--- pixel dimensions that let us derive a cell size. Querying the terminal
--- directly (CSI 14t) would mean reading from a tty Neovim owns, so we read
--- the cached TIOCGWINSZ values instead -- no interaction, no stolen input.
---@return {rows: integer, cols: integer, xpixel: integer, ypixel: integer}|nil
local function winsize()
  local script = [[
import fcntl, struct, sys, termios
try:
    with open('/dev/tty', 'rb') as f:
        r, c, x, y = struct.unpack('hhhh', fcntl.ioctl(f, termios.TIOCGWINSZ, b'\0' * 8))
    sys.stdout.write('%d %d %d %d' % (r, c, x, y))
except Exception:
    sys.exit(1)
]]
  if vim.fn.executable 'python3' == 1 then
    local res = vim.system({ 'python3', '-c', script }, { text = true }):wait(500)
    if res.code == 0 and res.stdout then
      local r, c, x, y = res.stdout:match '(%d+) (%d+) (%d+) (%d+)'
      if r then return { rows = tonumber(r), cols = tonumber(c), xpixel = tonumber(x), ypixel = tonumber(y) } end
    end
  end
  return nil
end

--- Pixel size of one terminal cell. Probed once, then cached until `reset()`.
---@return {width: integer, height: integer}
function M.cell_size()
  if cell_cache then return cell_cache end
  local cfg = require('inlineview.config').options.cell
  -- An explicit non-default config wins over the probe.
  local ws = winsize()
  if ws and ws.xpixel > 0 and ws.ypixel > 0 and ws.cols > 0 and ws.rows > 0 then
    cell_cache = {
      width = math.floor(ws.xpixel / ws.cols),
      height = math.floor(ws.ypixel / ws.rows),
    }
  else
    cell_cache = { width = cfg.width, height = cfg.height }
  end
  if cell_cache.width < 1 then cell_cache.width = cfg.width end
  if cell_cache.height < 1 then cell_cache.height = cfg.height end
  return cell_cache
end

--- Drop cached geometry/backend detection, e.g. after the font size changed.
function M.reset()
  cell_cache = nil
  M._backend = nil
end

--------------------------------------------------------------------------
-- Protocol detection
--------------------------------------------------------------------------

--- Which graphics protocol this terminal speaks.
---
--- Detection is env-based because querying is unreliable through SSH and
--- multiplexers. iTerm2 forwards LC_TERMINAL specifically so that remote
--- programs can identify it, and Kitty/Ghostty/WezTerm set their own markers.
---@return "iterm2"|"kitty"|"blocks"|"none"
function M.detect()
  local env = vim.env

  if env.LC_TERMINAL == 'iTerm2' or env.TERM_PROGRAM == 'iTerm.app' then return 'iterm2' end
  if env.KITTY_WINDOW_ID or (env.TERM or ''):match 'kitty' then return 'kitty' end
  if env.GHOSTTY_RESOURCES_DIR or env.TERM_PROGRAM == 'ghostty' then return 'kitty' end
  if env.WEZTERM_PANE or env.TERM_PROGRAM == 'WezTerm' then return 'kitty' end
  if env.TERM_PROGRAM == 'vscode' or env.KONSOLE_VERSION then return 'blocks' end
  -- Nothing identified itself. Unicode half-blocks work on any truecolor
  -- terminal, so prefer a degraded picture over no picture at all.
  if vim.fn.executable 'chafa' == 1 then return 'blocks' end
  return 'none'
end

--- Detected-or-configured backend name, cached.
---@return string
function M.backend_name()
  local configured = require('inlineview.config').options.backend
  if configured and configured ~= 'auto' then return configured end
  if not M._backend then M._backend = M.detect() end
  return M._backend
end

return M
