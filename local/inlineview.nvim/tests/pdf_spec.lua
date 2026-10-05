local imageinfo = require 'inlineview.imageinfo'
local pdf = require 'inlineview.pdf'

local SAMPLE = FIXTURES .. '/sample.pdf'

describe('pdf', function()
  it('finds poppler', function()
    local available, err = pdf.available()
    ok(available, tostring(err))
  end)

  it('reads the page count', function()
    local info, err = pdf.info(SAMPLE)
    ok(info, tostring(err))
    eq(3, info.pages)
  end)

  it('reads the page size in points', function()
    local info = pdf.info(SAMPLE)
    near(595, info.width, 1)
    near(842, info.height, 1)
  end)

  it('reads the size of an individual page', function()
    local w, h = pdf.page_size(SAMPLE, 2)
    near(595, w, 1)
    near(842, h, 1)
  end)

  it('errors cleanly on a file that is not a PDF', function()
    local info, err = pdf.info(FIXTURES .. '/gradient.png')
    falsy(info)
    ok(err)
  end)
end)

describe('pdf.render', function()
  it('rasterizes a page at the requested dpi', function()
    -- 595 pt at 72 dpi is 595 px; at 36 dpi it should be about half that.
    local png, err = pdf.render(SAMPLE, 1, 36)
    ok(png, tostring(err))
    ok(vim.uv.fs_stat(png), 'output file missing')

    local info = imageinfo.probe(png)
    ok(info)
    near(595 * 36 / 72, info.width, 2)
    near(842 * 36 / 72, info.height, 2)
  end)

  it('renders different pages to different files', function()
    local p1 = pdf.render(SAMPLE, 1, 36)
    local p2 = pdf.render(SAMPLE, 2, 36)
    ne(p1, p2)
    ok(vim.uv.fs_stat(p2))
  end)

  it('serves a repeated request from the cache', function()
    local first = pdf.render(SAMPLE, 3, 50)
    local mtime = vim.uv.fs_stat(first).mtime.nsec
    local second = pdf.render(SAMPLE, 3, 50)
    eq(first, second, 'cache should return the same path')
    eq(mtime, vim.uv.fs_stat(second).mtime.nsec, 'cached file should not be rewritten')
  end)

  it('refuses a page that does not exist', function()
    local png = pdf.render(SAMPLE, 99, 36)
    falsy(png)
  end)
end)

describe('pdf.render_region', function()
  it('crops to the requested rectangle', function()
    local region = { x = 10, y = 20, w = 100, h = 80 }
    local png, err = pdf.render_region(SAMPLE, 1, 72, region)
    ok(png, tostring(err))

    local info = imageinfo.probe(png)
    ok(info)
    eq(100, info.width)
    eq(80, info.height)
  end)

  it('produces a different image for a different offset', function()
    local a = pdf.render_region(SAMPLE, 1, 72, { x = 0, y = 0, w = 80, h = 80 })
    local b = pdf.render_region(SAMPLE, 1, 72, { x = 200, y = 300, w = 80, h = 80 })
    ne(a, b, 'crops should be cached separately')

    local da = io.open(a, 'rb'):read '*a'
    local db = io.open(b, 'rb'):read '*a'
    ne(da, db, 'different regions of the page should not be identical')
  end)

  it('clamps the crop to the page rather than failing', function()
    -- Asking past the edge of the page is normal while panning at high zoom.
    local png = pdf.render_region(SAMPLE, 1, 72, { x = 500, y = 700, w = 400, h = 400 })
    ok(png, 'poppler should still produce output')
    local info = imageinfo.probe(png)
    ok(info.width > 0 and info.height > 0)
  end)
end)

describe('pdf.render_async', function()
  it('delivers the path through the callback', function()
    local done, result, failure = false, nil, nil
    pdf.render_async(SAMPLE, 2, 48, function(png, err)
      result, failure, done = png, err, true
    end)

    vim.wait(30000, function() return done end, 20)

    ok(done, 'callback never fired')
    ok(result, tostring(failure))
    ok(vim.uv.fs_stat(result))
  end)

  it('reports failure through the callback instead of raising', function()
    local done, result, failure = false, nil, nil
    pdf.render_async(FIXTURES .. '/gradient.png', 1, 48, function(png, err)
      result, failure, done = png, err, true
    end)

    vim.wait(30000, function() return done end, 20)

    ok(done, 'callback never fired')
    falsy(result)
    ok(failure)
  end)
end)
