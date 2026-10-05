--- Kitty graphics protocol backend (Kitty, Ghostty, WezTerm).
---
--- Included so the plugin keeps working if the terminal changes. Unlike
--- iTerm2 this protocol has real placements: images carry ids and can be
--- deleted individually, so `clear` is precise and cheap.
---
--- Kitty only decodes PNG (`f=100`); other formats are reported unsupported
--- so the dispatcher can fall back to the blocks backend.
local terminal = require 'inlineview.terminal'
local util = require 'inlineview.util'

local M = {}

M.name = 'kitty'

--- Chunk size mandated by the protocol (base64 payload per escape).
local CHUNK = 4096

--- Ids we have transmitted, so clear_all can tidy up.
local placed = {}

function M.available() return terminal.has_writer() end

---@param path string
---@return boolean
function M.supports_path(path) return require('inlineview.config').ext(path) == 'png' end

---@param id integer
---@return string
local function esc(id, keys, payload) return table.concat { terminal.ESC, '_G', keys, payload and (';' .. payload) or '', terminal.ESC, '\\' } end

---@param spec {path: string, row: integer, col: integer, cols: integer, rows: integer, id: integer|nil}
---@return boolean ok, string|nil err
function M.draw(spec)
  local data, err = util.read_file(spec.path)
  if not data then return false, err or 'read failed' end

  local id = spec.id or 1
  local b64 = vim.base64.encode(data)

  local parts = {}
  local offset = 1
  local first = true
  while offset <= #b64 do
    local chunk = b64:sub(offset, offset + CHUNK - 1)
    offset = offset + CHUNK
    local more = offset <= #b64 and 1 or 0
    if first then
      -- a=T transmit+display, f=100 PNG, c/r target cell box, C=1 do not
      -- move the cursor, q=2 suppress replies (they would land in stdin).
      parts[#parts + 1] = esc(id, string.format('a=T,f=100,i=%d,c=%d,r=%d,C=1,q=2,m=%d', id, spec.cols, spec.rows, more), chunk)
      first = false
    else
      parts[#parts + 1] = esc(id, string.format('m=%d', more), chunk)
    end
  end

  if #parts == 0 then return false, 'empty image' end

  placed[id] = true
  terminal.write_at(spec.row, spec.col, table.concat(parts))
  return true
end

---@param id integer|nil
function M.clear(id)
  if id then
    placed[id] = nil
    terminal.write(esc(id, string.format('a=d,d=i,i=%d,q=2', id)))
    return
  end
  M.clear_all()
end

function M.clear_all()
  for id in pairs(placed) do
    terminal.write(esc(id, string.format('a=d,d=i,i=%d,q=2', id)))
  end
  placed = {}
end

return M
