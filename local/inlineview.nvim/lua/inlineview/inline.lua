--- In-buffer rendering of image links.
---
--- For prose filetypes, every `![alt](path)` style reference gets blank
--- `virt_lines` reserved beneath it, and the picture is painted into that gap.
--- The gap is real as far as Neovim is concerned, so the surrounding text
--- reflows correctly and scrolling behaves normally.
local backends = require 'inlineview.backends'
local config = require 'inlineview.config'
local geometry = require 'inlineview.geometry'
local imageinfo = require 'inlineview.imageinfo'
local pdf = require 'inlineview.pdf'
local terminal = require 'inlineview.terminal'
local util = require 'inlineview.util'

local M = {}

local ns = vim.api.nvim_create_namespace 'inlineview_inline'

--- buf -> true for buffers we are managing
---@type table<integer, boolean>
M.enabled = {}

--- Link syntaxes we understand. Each pattern captures a single path.
local PATTERNS = {
  '!%[[^%]]*%]%(([^%)]+)%)', -- markdown: ![alt](path)
  '%[%[file:([^%]]+)%]%]', -- org / neorg: [[file:path]]
  '<img[^>]-src=["\']([^"\']+)["\']', -- html: <img src="path">
}

---@param raw string
---@return string
local function strip_title(raw)
  -- `![](a.png "caption")` and angle-bracket forms.
  return (raw:gsub('%s+["\'].*$', ''):gsub('^<(.*)>$', '%1'):gsub('%s+$', ''))
end

---@param buf integer
---@param raw string
---@return string|nil
local function resolve(buf, raw)
  local path = strip_title(raw)
  if path == '' or path:match '^%a[%w+.-]*://' then
    return nil -- remote URLs are out of scope
  end
  path = vim.fn.expand(path)
  if path:sub(1, 1) == '/' then return util.exists(path) and path or nil end

  local name = vim.api.nvim_buf_get_name(buf)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  local candidates = { vim.fs.joinpath(dir, path), vim.fs.joinpath(vim.fn.getcwd(), path) }
  for _, candidate in ipairs(candidates) do
    if util.exists(candidate) then return vim.fn.fnamemodify(candidate, ':p') end
  end
  return nil
end

--- Image links found in `lines`, as 1-based line numbers.
---@param buf integer
---@param first integer  1-based inclusive
---@param last integer   1-based inclusive
---@return {lnum: integer, path: string, kind: string}[]
function M.find_links(buf, first, last)
  local total = vim.api.nvim_buf_line_count(buf)
  first = math.max(first, 1)
  last = math.min(last, total)
  if first > last then return {} end

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local found = {}
  for i, line in ipairs(lines) do
    for _, pattern in ipairs(PATTERNS) do
      local raw = line:match(pattern)
      if raw then
        local path = resolve(buf, raw)
        local kind = path and config.kind(path)
        if path and kind then found[#found + 1] = { lnum = first + i - 1, path = path, kind = kind } end
        break
      end
    end
  end
  return found
end

--- Decide how many cells an inline image should occupy.
---@param link table
---@param max_cols integer
---@return {cols: integer, rows: integer, path: string}|nil
local function measure(link, max_cols)
  local cell = terminal.cell_size()
  local max_rows = config.options.inline.max_rows

  if link.kind == 'pdf' then
    local pts_w, pts_h = pdf.page_size(link.path, 1)
    local size = geometry.fit {
      width = pts_w,
      height = pts_h,
      cell_width = cell.width,
      cell_height = cell.height,
      max_cols = max_cols,
      max_rows = max_rows,
      fit = 'fit',
    }
    local dpi = geometry.dpi_for(pts_w, size.cols * cell.width, config.options.pdf.min_dpi, config.options.pdf.max_dpi)
    local png = pdf.render(link.path, 1, dpi)
    if not png then return nil end
    return { cols = size.cols, rows = size.rows, path = png }
  end

  local info = imageinfo.probe(link.path)
  if not info then return nil end
  local size = geometry.fit {
    width = info.width,
    height = info.height,
    cell_width = cell.width,
    cell_height = cell.height,
    max_cols = max_cols,
    max_rows = max_rows,
    fit = 'contain',
  }
  return { cols = size.cols, rows = size.rows, path = link.path }
end

---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

--- Reserve space for, and paint, every link near the viewport of `win`.
---@param win integer
function M.render_win(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.enabled[buf] then return end

  local margin = config.options.inline.render_margin
  local top = vim.fn.line('w0', win)
  local bot = vim.fn.line('w$', win)
  local links = M.find_links(buf, top - margin, bot + margin)

  local info = vim.fn.getwininfo(win)[1]
  local max_cols = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
  if max_cols < 1 then return end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Pass 1: reserve the gaps, so that screen positions settle before we ask
  -- where anything ended up.
  local placed = {}
  for _, link in ipairs(links) do
    local frame = measure(link, max_cols)
    if frame then
      local filler = {}
      for _ = 1, frame.rows do
        filler[#filler + 1] = { { '', 'Normal' } }
      end
      vim.api.nvim_buf_set_extmark(buf, ns, link.lnum - 1, 0, {
        virt_lines = filler,
        virt_lines_above = false,
      })
      placed[#placed + 1] = { link = link, frame = frame }
    end
  end

  if #placed == 0 then return end

  -- Pass 2: paint. `all - fill` is the line's own height excluding the
  -- virtual lines we just added, which is exactly where the gap begins.
  for _, item in ipairs(placed) do
    local anchor = vim.fn.screenpos(win, item.link.lnum, 1)
    if anchor.row > 0 then
      local th = vim.api.nvim_win_text_height(win, {
        start_row = item.link.lnum - 1,
        end_row = item.link.lnum - 1,
      })
      local own_height = th.all - (th.fill or 0)
      local row = anchor.row + own_height
      local backend = backends.resolve(item.frame.path)
      if backend and row + item.frame.rows - 1 <= vim.o.lines - 1 then
        pcall(backend.draw, {
          path = item.frame.path,
          row = row,
          col = anchor.col,
          cols = item.frame.cols,
          rows = item.frame.rows,
          id = 10000 + item.link.lnum,
        })
      end
    end
  end
end

--- Repaint inline images in all visible windows.
function M.render_all()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    pcall(M.render_win, win)
  end
end

---@param buf integer
---@return boolean enabled
function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if M.enabled[buf] then
    M.enabled[buf] = nil
    M.clear(buf)
    vim.schedule(function() pcall(vim.cmd, 'redraw!') end)
    return false
  end
  M.enabled[buf] = true
  M.render_all()
  return true
end

---@param buf integer
function M.maybe_enable(buf)
  local cfg = config.options.inline
  if not cfg.enabled then return end
  if vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype) then
    M.enabled[buf] = true
    M.render_all()
  end
end

return M
