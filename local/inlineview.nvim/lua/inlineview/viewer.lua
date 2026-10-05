--- Document state and painting.
---
--- Design notes
---
--- A "document" is attached to a *buffer*, while painting happens per
--- *window*. Keeping those separate means the same PDF shown in two splits
--- works, and a buffer opened by `BufReadCmd` behaves exactly like one created
--- by `:InlineView`.
---
--- The image is positioned with `screenpos()` of buffer line 2 rather than by
--- doing arithmetic on window geometry. That one call already accounts for
--- borders, sign/number columns and winbar, so there is nothing to get wrong
--- when any of those change. Line 1 is reserved as a text status line, which
--- also gives the cursor somewhere harmless to sit.
local backends = require 'inlineview.backends'
local config = require 'inlineview.config'
local geometry = require 'inlineview.geometry'
local imageinfo = require 'inlineview.imageinfo'
local pdf = require 'inlineview.pdf'
local terminal = require 'inlineview.terminal'
local util = require 'inlineview.util'

local M = {}

--- buf -> document state
---@type table<integer, table>
M.docs = {}

local ns = vim.api.nvim_create_namespace 'inlineview'

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

---@param buf integer
---@return table|nil
function M.get(buf)
  local doc = M.docs[buf]
  if doc and not vim.api.nvim_buf_is_valid(buf) then
    M.docs[buf] = nil
    return nil
  end
  return doc
end

--- Windows in the current tabpage displaying a registered document.
---@return {win: integer, buf: integer, doc: table}[]
local function visible_docs()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local doc = M.get(buf)
      if doc then out[#out + 1] = { win = win, buf = buf, doc = doc } end
    end
  end
  return out
end

---@param doc table
---@return string
local function status_text(doc)
  local parts = { vim.fn.fnamemodify(doc.path, ':t') }
  if doc.kind == 'pdf' then parts[#parts + 1] = string.format('page %d/%d', doc.page, doc.pages or 1) end
  if doc.zoom and math.abs(doc.zoom - 1) > 0.001 then parts[#parts + 1] = string.format('%d%%', math.floor(doc.zoom * 100 + 0.5)) end
  if doc.fit ~= config.options.fit then parts[#parts + 1] = doc.fit end
  parts[#parts + 1] = terminal.backend_name()
  if doc.err then parts[#parts + 1] = 'ERROR: ' .. doc.err end
  return '  ' .. table.concat(parts, '  ·  ') .. '  '
end

--- Keep the scratch buffer exactly as tall as the window, so Neovim paints a
--- clean background under the image and no `~` markers show through.
---@param buf integer
---@param win integer
---@param doc table
local function sync_buffer(buf, win, doc)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local height = vim.api.nvim_win_get_height(win)
  local lines = { status_text(doc) }
  for _ = 2, math.max(height, 2) do
    lines[#lines + 1] = ''
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = doc.err and 'ErrorMsg' or 'Title',
    hl_mode = 'combine',
  })
end

--- Window options that keep the text area predictable and free of decoration.
---@param win integer
local function configure_window(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.cursorcolumn = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.colorcolumn = ''
  wo.fillchars = 'eob: '
end

--------------------------------------------------------------------------
-- Frame computation
--------------------------------------------------------------------------

--- Work out what to draw and how big, for the given window area.
---
--- Returns the path to a ready-to-blit image plus its size in cells. For PDFs
--- at zoom > 1 this rasterizes only the visible crop at a higher dpi, so
--- zooming sharpens the text instead of magnifying pixels.
---
---@param doc table
---@param max_cols integer
---@param max_rows integer
---@return {path: string, cols: integer, rows: integer}|nil frame, string|nil err
function M.frame(doc, max_cols, max_rows)
  local cell = terminal.cell_size()

  if doc.kind == 'image' then
    local info, err = imageinfo.probe(doc.path)
    if not info then return nil, err end
    local size = geometry.fit {
      width = info.width,
      height = info.height,
      cell_width = cell.width,
      cell_height = cell.height,
      max_cols = max_cols,
      max_rows = max_rows,
      fit = doc.fit,
      zoom = doc.zoom,
    }
    return { path = doc.path, cols = size.cols, rows = size.rows }
  end

  -- PDF.
  local pts_w, pts_h = pdf.page_size(doc.path, doc.page)

  -- Size the page as if it were an image whose pixels are points; this gives
  -- the unzoomed "fits the window" footprint in cells.
  local base = geometry.fit {
    width = pts_w,
    height = pts_h,
    cell_width = cell.width,
    cell_height = cell.height,
    max_cols = max_cols,
    max_rows = max_rows,
    fit = doc.fit == 'contain' and 'fit' or doc.fit, -- a page should fill the window
    zoom = 1,
  }

  local virtual_cols = math.max(math.floor(base.cols * doc.zoom + 0.5), 1)
  local virtual_rows = math.max(math.floor(base.rows * doc.zoom + 0.5), 1)
  local vis_cols = math.min(virtual_cols, max_cols)
  local vis_rows = math.min(virtual_rows, max_rows)

  -- Clamp the pan offset to whatever is actually off-screen.
  doc.pan.x = math.floor(util.clamp(doc.pan.x, 0, virtual_cols - vis_cols))
  doc.pan.y = math.floor(util.clamp(doc.pan.y, 0, virtual_rows - vis_rows))

  local cfg = config.options.pdf
  local dpi = geometry.dpi_for(pts_w, virtual_cols * cell.width, cfg.min_dpi, cfg.max_dpi)

  -- No zoom and nothing panned: render the whole page and reuse the cache.
  if vis_cols == virtual_cols and vis_rows == virtual_rows then
    local png, err = pdf.render(doc.path, doc.page, dpi)
    if not png then return nil, err end
    return { path = png, cols = vis_cols, rows = vis_rows }
  end

  -- Crop in the rasterized page's pixel space. Working in fractions keeps
  -- this correct even when dpi got clamped and the render is not the size we
  -- originally asked for.
  local rendered_w = pts_w * dpi / 72
  local rendered_h = pts_h * dpi / 72
  local region = {
    x = math.floor(doc.pan.x / virtual_cols * rendered_w),
    y = math.floor(doc.pan.y / virtual_rows * rendered_h),
    w = math.ceil(vis_cols / virtual_cols * rendered_w),
    h = math.ceil(vis_rows / virtual_rows * rendered_h),
  }

  local png, err = pdf.render_region(doc.path, doc.page, dpi, region)
  if not png then return nil, err end
  return { path = png, cols = vis_cols, rows = vis_rows }
end

--------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------

--- Draw one document into one window.
---@param win integer
---@param buf integer
---@param doc table
function M.paint_win(win, buf, doc)
  if not vim.api.nvim_win_is_valid(win) then return end

  sync_buffer(buf, win, doc)

  local height = vim.api.nvim_win_get_height(win)
  local width = vim.api.nvim_win_get_width(win)
  -- Line 1 holds the status text; the image lives below it.
  local max_rows = height - 1
  local info = vim.fn.getwininfo(win)[1]
  local max_cols = width - (info and info.textoff or 0)
  if max_rows < 1 or max_cols < 1 then return end

  local backend, berr = backends.resolve(doc.path)
  if not backend then
    doc.err = berr
    sync_buffer(buf, win, doc)
    return
  end

  local frame, ferr = M.frame(doc, max_cols, max_rows)
  if not frame then
    doc.err = ferr
    sync_buffer(buf, win, doc)
    return
  end

  -- Ask Neovim where buffer line 2 actually landed on screen. This is the
  -- single source of truth for placement.
  local pos = vim.fn.screenpos(win, 2, 1)
  if pos.row == 0 then
    return -- line 2 is scrolled out of view
  end

  local offset = geometry.center(frame.cols, frame.rows, max_cols, max_rows)
  local ok, derr = backend.draw {
    path = frame.path,
    row = pos.row + offset.row,
    col = pos.col + offset.col,
    cols = frame.cols,
    rows = frame.rows,
    id = buf,
  }

  local previous = doc.err
  doc.err = ok and nil or derr
  if doc.err ~= previous then sync_buffer(buf, win, doc) end

  if doc.kind == 'pdf' and config.options.pdf.prefetch > 0 then
    local cell = terminal.cell_size()
    local pts_w = select(1, pdf.page_size(doc.path, doc.page))
    local dpi = geometry.dpi_for(pts_w, frame.cols * cell.width, config.options.pdf.min_dpi, config.options.pdf.max_dpi)
    pdf.prefetch(doc.path, doc.page, dpi, config.options.pdf.prefetch)
  end
end

--- Repaint every visible document.
---@param opts {erase: boolean|nil}|nil
function M.paint_all(opts)
  opts = opts or {}
  local targets = visible_docs()
  if #targets == 0 then return end

  -- iTerm2 has no per-image delete, so shrinking or replacing an image means
  -- making Neovim repaint the cells underneath first.
  if opts.erase then pcall(vim.cmd, 'redraw!') end

  for _, t in ipairs(targets) do
    local ok, err = pcall(M.paint_win, t.win, t.buf, t.doc)
    if not ok then t.doc.err = tostring(err) end
  end
end

M.paint_debounced = util.debounce(config.defaults.debounce, function() M.paint_all() end)

--- Erase everything and forget placements. Used on close and on :InlineClear.
function M.clear_all()
  backends.clear_all()
  vim.schedule(function() pcall(vim.cmd, 'redraw!') end)
end

--------------------------------------------------------------------------
-- Document lifecycle
--------------------------------------------------------------------------

--- Register `buf` as a view of `path` and prepare it for painting.
---@param buf integer
---@param path string
---@return table|nil doc, string|nil err
function M.attach(buf, path)
  path = vim.fn.fnamemodify(path, ':p')
  if not util.exists(path) then return nil, 'no such file: ' .. path end

  local kind = config.kind(path)
  if not kind then return nil, 'not a viewable image or PDF: ' .. vim.fn.fnamemodify(path, ':t') end

  local doc = {
    path = path,
    kind = kind,
    page = 1,
    pages = 1,
    zoom = 1,
    fit = config.options.fit,
    pan = { x = 0, y = 0 },
  }

  if kind == 'pdf' then
    local ok, err = pdf.available()
    if not ok then return nil, err end
    local info, ierr = pdf.info(path)
    if not info then return nil, ierr end
    doc.pages = info.pages
  end

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = 'inlineview'
  vim.bo[buf].modifiable = false

  M.docs[buf] = doc
  M.install_keymaps(buf)
  return doc
end

---@param buf integer
function M.detach(buf)
  M.docs[buf] = nil
  local backend = backends.get(terminal.backend_name())
  if backend and backend.clear then pcall(backend.clear, buf) end
  M.clear_all()
end

--------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------

--- Apply a state change and repaint with an erase pass.
---@param buf integer
---@param fn fun(doc: table)
local function mutate(buf, fn)
  local doc = M.get(buf)
  if not doc then return end
  fn(doc)
  M.paint_all { erase = true }
end

---@param buf integer
---@param delta integer
function M.goto_page(buf, delta, absolute)
  mutate(buf, function(doc)
    if doc.kind ~= 'pdf' then return end
    local target = absolute and delta or (doc.page + delta)
    doc.page = math.floor(util.clamp(target, 1, doc.pages))
    doc.pan = { x = 0, y = 0 }
  end)
end

---@param buf integer
---@param factor number
function M.zoom(buf, factor)
  mutate(buf, function(doc) doc.zoom = util.clamp(doc.zoom * factor, 0.1, 20) end)
end

---@param buf integer
function M.zoom_reset(buf)
  mutate(buf, function(doc)
    doc.zoom = 1
    doc.pan = { x = 0, y = 0 }
  end)
end

---@param buf integer
---@param mode string
function M.set_fit(buf, mode)
  mutate(buf, function(doc)
    doc.fit = mode
    doc.pan = { x = 0, y = 0 }
  end)
end

---@param buf integer
---@param dx integer
---@param dy integer
function M.pan(buf, dx, dy)
  mutate(buf, function(doc)
    if doc.kind ~= 'pdf' then return end
    doc.pan.x = doc.pan.x + dx
    doc.pan.y = doc.pan.y + dy
  end)
end

---@param buf integer
function M.close(buf)
  local win = vim.fn.bufwinid(buf)
  M.detach(buf)
  if win ~= -1 and vim.api.nvim_win_is_valid(win) then
    -- Closing the last window would exit Neovim; fall back to a scratch buffer.
    if #vim.api.nvim_tabpage_list_wins(0) > 1 or vim.fn.tabpagenr '$' > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    else
      pcall(vim.api.nvim_win_set_buf, win, vim.api.nvim_create_buf(true, true))
    end
  end
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

--------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------

local HELP = {
  'inlineview',
  '',
  'q / <Esc>      close',
  'n / p          next / previous page (PDF)',
  'gg / G         first / last page (PDF)',
  '<count>%       jump to page (PDF)',
  '+ / - / 0      zoom in / out / reset',
  'h j k l        pan when zoomed (PDF)',
  'w              fit to width',
  'f              fit to window',
  '<C-l>          force repaint',
  '?              this help',
}

---@param buf integer
function M.install_keymaps(buf)
  local km = config.options.keymaps
  if not km.enabled then return end

  local function map(lhs, fn, desc)
    for _, key in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end

  map(km.close, function() M.close(buf) end, 'inlineview: close')

  map(km.next_page, function() M.goto_page(buf, 1) end, 'inlineview: next page')

  map(km.prev_page, function() M.goto_page(buf, -1) end, 'inlineview: previous page')

  map(km.first_page, function() M.goto_page(buf, 1, true) end, 'inlineview: first page')

  map(km.last_page, function()
    local doc = M.get(buf)
    M.goto_page(buf, doc and doc.pages or 1, true)
  end, 'inlineview: last page')

  -- `5%` jumps to page 5, mirroring how `%` works for file position elsewhere.
  map('%', function()
    local count = vim.v.count
    if count > 0 then M.goto_page(buf, count, true) end
  end, 'inlineview: go to page [count]')

  map(km.zoom_in, function() M.zoom(buf, config.options.zoom_step) end, 'inlineview: zoom in')

  map(km.zoom_out, function() M.zoom(buf, 1 / config.options.zoom_step) end, 'inlineview: zoom out')

  map(km.zoom_reset, function() M.zoom_reset(buf) end, 'inlineview: reset zoom')

  map(km.fit_width, function() M.set_fit(buf, 'width') end, 'inlineview: fit width')

  map(km.fit_contain, function() M.set_fit(buf, 'fit') end, 'inlineview: fit window')

  map(km.refresh, function() M.paint_all { erase = true } end, 'inlineview: repaint')

  for key, d in pairs { h = { -2, 0 }, l = { 2, 0 }, j = { 0, 2 }, k = { 0, -2 } } do
    map(key, function() M.pan(buf, d[1], d[2]) end, 'inlineview: pan')
  end

  map(km.help, function() vim.notify(table.concat(HELP, '\n'), vim.log.levels.INFO, { title = 'inlineview' }) end, 'inlineview: help')
end

--------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------

--- Open `path` in a floating window.
---@param path string
---@return integer|nil buf, string|nil err
function M.open_float(path)
  local cfg = config.options
  local width = math.floor(vim.o.columns * cfg.width)
  local height = math.floor(vim.o.lines * cfg.height)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
  })

  local doc, err = M.attach(buf, path)
  if not doc then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, err
  end

  configure_window(win)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 }) end
    M.paint_all { erase = true }
  end)
  return buf
end

--- Take over an existing buffer/window, used by the `BufReadCmd` handler so
--- that `nvim diagram.png` shows the picture instead of binary soup.
---@param buf integer
---@param path string
---@return integer|nil buf, string|nil err
function M.open_in_buffer(buf, path)
  local doc, err = M.attach(buf, path)
  if not doc then return nil, err end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then configure_window(win) end
  vim.schedule(function()
    local w = vim.fn.bufwinid(buf)
    if w ~= -1 then pcall(vim.api.nvim_win_set_cursor, w, { 1, 0 }) end
    M.paint_all { erase = true }
  end)
  return buf
end

return M
