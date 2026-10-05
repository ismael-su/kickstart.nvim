--- PDF support, backed by poppler (`pdfinfo` + `pdftoppm`).
---
--- Pages are rasterized to PNG at a dpi derived from the viewer size, then
--- cached on disk keyed by (file, mtime, page, dpi) so paging back and forth
--- and repainting on scroll are free.
local util = require 'inlineview.util'

local M = {}

---@return boolean ok, string|nil err
function M.available()
  if vim.fn.executable 'pdftoppm' ~= 1 then return false, 'pdftoppm not found (install poppler-utils)' end
  if vim.fn.executable 'pdfinfo' ~= 1 then return false, 'pdfinfo not found (install poppler-utils)' end
  return true
end

local info_cache = {}

--- Page count and page geometry.
---
--- `pdfinfo` reports the size of the first page by default; pages with
--- differing sizes are queried individually by `page_size`.
---@param path string
---@return {pages: integer, width: number, height: number}|nil info, string|nil err
function M.info(path)
  local ok, err = M.available()
  if not ok then return nil, err end

  local key = path .. ':' .. util.mtime(path)
  if info_cache[key] then return info_cache[key] end

  local res = vim.system({ 'pdfinfo', path }, { text = true }):wait(10000)
  if res.code ~= 0 then return nil, ((res.stderr or 'pdfinfo failed'):gsub('%s+$', '')) end

  local out = res.stdout or ''
  local pages = tonumber(out:match 'Pages:%s+(%d+)')
  local w, h = out:match 'Page size:%s+([%d%.]+)%s+x%s+([%d%.]+)'
  if not pages then return nil, 'could not determine page count' end

  local result = {
    pages = pages,
    width = tonumber(w) or 612,
    height = tonumber(h) or 792,
  }
  info_cache[key] = result
  return result
end

--- Size of one specific page, falling back to the document default.
---@param path string
---@param page integer
---@return number width, number height
function M.page_size(path, page)
  local doc = M.info(path)
  local fallback_w = doc and doc.width or 612
  local fallback_h = doc and doc.height or 792

  local res = vim.system({ 'pdfinfo', '-f', tostring(page), '-l', tostring(page), path }, { text = true }):wait(10000)
  if res.code == 0 and res.stdout then
    local w, h = res.stdout:match 'Page%s+%d+%s+size:%s+([%d%.]+)%s+x%s+([%d%.]+)'
    if w and h then return tonumber(w), tonumber(h) end
  end
  return fallback_w, fallback_h
end

--- On-disk location a rasterized page would occupy.
---@param path string
---@param page integer
---@param dpi integer
---@return string prefix  path without the `.png` suffix, as pdftoppm wants
local function cache_prefix(path, page, dpi)
  local dir = vim.fs.joinpath(util.cache_dir(), util.hash(path .. ':' .. util.mtime(path)))
  vim.fn.mkdir(dir, 'p')
  return vim.fs.joinpath(dir, string.format('p%d-%d', page, dpi))
end

---@param path string
---@param page integer
---@param dpi integer
---@return string[]
local function pdftoppm_cmd(path, page, dpi, prefix)
  return {
    'pdftoppm',
    '-png',
    '-r',
    tostring(dpi),
    '-f',
    tostring(page),
    '-l',
    tostring(page),
    '-singlefile',
    path,
    prefix,
  }
end

--- Rasterize a page, blocking until it is on disk.
---@param path string
---@param page integer
---@param dpi integer
---@return string|nil png_path, string|nil err
function M.render(path, page, dpi)
  local ok, err = M.available()
  if not ok then return nil, err end

  local prefix = cache_prefix(path, page, dpi)
  local png = prefix .. '.png'
  if util.exists(png) then return png end

  local res = vim.system(pdftoppm_cmd(path, page, dpi, prefix), { text = true }):wait(30000)
  if res.code ~= 0 then return nil, ((res.stderr or 'pdftoppm failed'):gsub('%s+$', '')) end
  if not util.exists(png) then return nil, 'pdftoppm produced no output' end
  return png
end

--- Rasterize without blocking the UI; `cb(png_path, err)` runs on the main loop.
---@param path string
---@param page integer
---@param dpi integer
---@param cb fun(png: string|nil, err: string|nil)
function M.render_async(path, page, dpi, cb)
  local ok, err = M.available()
  if not ok then return cb(nil, err) end

  local prefix = cache_prefix(path, page, dpi)
  local png = prefix .. '.png'
  if util.exists(png) then return cb(png) end

  vim.system(pdftoppm_cmd(path, page, dpi, prefix), { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then return cb(nil, ((res.stderr or 'pdftoppm failed'):gsub('%s+$', ''))) end
      if not util.exists(png) then return cb(nil, 'pdftoppm produced no output') end
      cb(png)
    end)
  end)
end

--- Rasterize a sub-rectangle of a page.
---
--- This is what makes zooming a PDF genuinely useful: rather than upscaling a
--- fitted render, the page is rasterized at a higher dpi and only the visible
--- window is written out, so small text becomes sharper instead of blurrier.
---
---@param path string
---@param page integer
---@param dpi integer
---@param region {x: integer, y: integer, w: integer, h: integer}  pixels at `dpi`
---@return string|nil png_path, string|nil err
function M.render_region(path, page, dpi, region)
  local ok, err = M.available()
  if not ok then return nil, err end

  local prefix = cache_prefix(path, page, dpi) .. string.format('-x%dy%dw%dh%d', region.x, region.y, region.w, region.h)
  local png = prefix .. '.png'
  if util.exists(png) then return png end

  local cmd = {
    'pdftoppm',
    '-png',
    '-r',
    tostring(dpi),
    '-f',
    tostring(page),
    '-l',
    tostring(page),
    '-singlefile',
    '-x',
    tostring(region.x),
    '-y',
    tostring(region.y),
    '-W',
    tostring(region.w),
    '-H',
    tostring(region.h),
    path,
    prefix,
  }

  local res = vim.system(cmd, { text = true }):wait(30000)
  if res.code ~= 0 then return nil, ((res.stderr or 'pdftoppm failed'):gsub('%s+$', '')) end
  if not util.exists(png) then return nil, 'pdftoppm produced no output' end
  return png
end

--- Warm the cache for pages after `page`, so paging forward feels instant.
---@param path string
---@param page integer
---@param dpi integer
---@param count integer
function M.prefetch(path, page, dpi, count)
  local doc = M.info(path)
  if not doc then return end
  for n = page + 1, math.min(page + count, doc.pages) do
    M.render_async(path, n, dpi, function() end)
  end
end

return M
