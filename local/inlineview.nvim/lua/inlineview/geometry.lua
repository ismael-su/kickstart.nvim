--- Pure scaling arithmetic: pixels in, terminal cells out.
--- Kept free of Neovim API calls so it can be unit tested directly.
local M = {}

--- Size an image to a cell rectangle.
---
--- The result never exceeds max_cols/max_rows, so a caller can blit it into a
--- window without the terminal scrolling underneath Neovim.
---
---@param opts {width: integer, height: integer, cell_width: integer, cell_height: integer, max_cols: integer, max_rows: integer, fit: string|nil, zoom: number|nil, rotation: integer|nil}
---@return {cols: integer, rows: integer}
function M.fit(opts)
  local iw, ih = opts.width, opts.height
  assert(iw and iw > 0 and ih and ih > 0, 'image dimensions must be positive')

  -- A quarter turn swaps the axes before any scaling happens.
  local rotation = (opts.rotation or 0) % 360
  if rotation == 90 or rotation == 270 then
    iw, ih = ih, iw
  end

  local cw = math.max(opts.cell_width or 1, 1)
  local ch = math.max(opts.cell_height or 1, 1)
  local max_cols = math.max(opts.max_cols or 1, 1)
  local max_rows = math.max(opts.max_rows or 1, 1)

  -- Natural size expressed in cells.
  local nat_cols = iw / cw
  local nat_rows = ih / ch

  local by_width = max_cols / nat_cols
  local by_height = max_rows / nat_rows

  local scale
  local mode = opts.fit or 'contain'
  if mode == 'original' then
    scale = 1
  elseif mode == 'width' then
    scale = by_width
  elseif mode == 'height' then
    scale = by_height
  elseif mode == 'fit' then
    scale = math.min(by_width, by_height)
  else -- "contain": fit inside, but never blow up a small image
    scale = math.min(by_width, by_height, 1)
  end

  scale = scale * (opts.zoom or 1)

  local cols = math.floor(nat_cols * scale + 0.5)
  local rows = math.floor(nat_rows * scale + 0.5)

  -- Clamp to the window. Done after zoom so zooming past the edge crops to the
  -- window rather than overflowing it.
  cols = math.min(math.max(cols, 1), max_cols)
  rows = math.min(math.max(rows, 1), max_rows)

  return { cols = cols, rows = rows }
end

--- Top-left offset that centres a `cols`x`rows` block in the given area.
---@param cols integer
---@param rows integer
---@param max_cols integer
---@param max_rows integer
---@return {col: integer, row: integer}  zero-based offsets
function M.center(cols, rows, max_cols, max_rows)
  return {
    col = math.max(math.floor((max_cols - cols) / 2), 0),
    row = math.max(math.floor((max_rows - rows) / 2), 0),
  }
end

--- DPI needed to rasterize a page of `points_wide` into `target_px` pixels.
---@param points_wide number  page width in PostScript points (1/72 inch)
---@param target_px number    desired pixel width
---@param min_dpi number
---@param max_dpi number
---@return integer
function M.dpi_for(points_wide, target_px, min_dpi, max_dpi)
  if not points_wide or points_wide <= 0 then return math.floor(min_dpi) end
  local dpi = target_px * 72 / points_wide
  if dpi < min_dpi then dpi = min_dpi end
  if dpi > max_dpi then dpi = max_dpi end
  return math.floor(dpi + 0.5)
end

return M
