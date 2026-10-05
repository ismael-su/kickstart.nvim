local geometry = require 'inlineview.geometry'

--- A 10x20 px cell is close to a real terminal and makes the arithmetic easy
--- to follow: a 200x400 image is exactly 20x20 cells.
local CELL = { cell_width = 10, cell_height = 20 }

local function fit(opts) return geometry.fit(vim.tbl_extend('force', CELL, opts)) end

describe('geometry.fit', function()
  it('maps pixels to cells at natural size when there is room', function()
    local r = fit { width = 200, height = 400, max_cols = 100, max_rows = 100 }
    eq({ cols = 20, rows = 20 }, r)
  end)

  it('"contain" shrinks an oversized image but preserves aspect', function()
    -- 400x800 px = 40x40 cells, into a 20x20 window.
    local r = fit { width = 400, height = 800, max_cols = 20, max_rows = 20 }
    eq({ cols = 20, rows = 20 }, r)
  end)

  it('"contain" refuses to enlarge a small image', function()
    local r = fit { width = 20, height = 40, max_cols = 100, max_rows = 100, fit = 'contain' }
    eq({ cols = 2, rows = 2 }, r)
  end)

  it('"fit" does enlarge to fill the window', function()
    local r = fit { width = 20, height = 40, max_cols = 100, max_rows = 100, fit = 'fit' }
    -- Natural 2x2 cells scaled by min(50, 50) = 50.
    eq({ cols = 100, rows = 100 }, r)
  end)

  it('"fit" is limited by the tighter axis', function()
    -- 100x100 px against a 10x20 cell is 10x5 cells: width allows 4x,
    -- height allows 8x, so width binds and the result is 40x20 -- the image
    -- fills the window horizontally and is letterboxed vertically.
    local r = fit { width = 100, height = 100, max_cols = 40, max_rows = 40, fit = 'fit' }
    eq({ cols = 40, rows = 20 }, r)
  end)

  it('"width" matches the window width and lets height follow', function()
    local r = fit { width = 200, height = 400, max_cols = 40, max_rows = 1000, fit = 'width' }
    eq(40, r.cols)
    eq(40, r.rows) -- aspect preserved: 20x20 natural, scaled 2x
  end)

  it('"height" matches the window height', function()
    local r = fit { width = 200, height = 400, max_cols = 1000, max_rows = 10, fit = 'height' }
    eq(10, r.rows)
    eq(10, r.cols)
  end)

  it('"original" ignores the window except for clamping', function()
    local r = fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000, fit = 'original' }
    eq({ cols = 20, rows = 20 }, r)
  end)

  it('never exceeds the window, even when asked to', function()
    local r = fit { width = 200, height = 400, max_cols = 5, max_rows = 7, fit = 'original', zoom = 10 }
    eq({ cols = 5, rows = 7 }, r)
  end)

  it('applies zoom on top of the fit mode', function()
    local r = fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000, zoom = 2 }
    eq({ cols = 40, rows = 40 }, r)
  end)

  it('zooming out shrinks', function()
    local r = fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000, zoom = 0.5 }
    eq({ cols = 10, rows = 10 }, r)
  end)

  it('swaps axes for quarter-turn rotations', function()
    local upright = fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000 }
    local turned = fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000, rotation = 90 }
    eq({ cols = 20, rows = 20 }, upright)
    -- 400x200 px against a 10x20 cell = 40x10 cells.
    eq({ cols = 40, rows = 10 }, turned)
  end)

  it(
    'treats 180 degrees as unrotated for sizing',
    function()
      eq(
        fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000 },
        fit { width = 200, height = 400, max_cols = 1000, max_rows = 1000, rotation = 180 }
      )
    end
  )

  it('always returns at least one cell', function()
    local r = fit { width = 1, height = 1, max_cols = 50, max_rows = 50 }
    ok(r.cols >= 1 and r.rows >= 1)
  end)

  it('rejects degenerate images rather than dividing by zero', function()
    throws(function() fit { width = 0, height = 10, max_cols = 10, max_rows = 10 } end)
  end)
end)

describe('geometry.center', function()
  it('centres a smaller block', function() eq({ col = 5, row = 2 }, geometry.center(10, 6, 20, 10)) end)

  it('clamps to zero when the block fills the area', function() eq({ col = 0, row = 0 }, geometry.center(20, 10, 20, 10)) end)

  it('never returns a negative offset', function()
    local r = geometry.center(40, 40, 10, 10)
    ok(r.col >= 0 and r.row >= 0)
  end)
end)

describe('geometry.dpi_for', function()
  it('solves for the dpi that yields the requested pixel width', function()
    -- 612 pt wide at 72 dpi is 612 px; asking for 1224 px needs 144 dpi.
    eq(144, geometry.dpi_for(612, 1224, 36, 400))
  end)

  it('clamps to the configured ceiling', function() eq(400, geometry.dpi_for(612, 100000, 36, 400)) end)

  it('clamps to the configured floor', function() eq(36, geometry.dpi_for(612, 1, 36, 400)) end)

  it('falls back to the floor for a nonsense page width', function() eq(36, geometry.dpi_for(0, 1000, 36, 400)) end)
end)
