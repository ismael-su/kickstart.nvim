local terminal = require 'inlineview.terminal'
local viewer = require 'inlineview.viewer'

local PNG = FIXTURES .. '/gradient.png' -- 200x120
local TALL = FIXTURES .. '/tall.png' -- 60x400
local PDF = FIXTURES .. '/sample.pdf' -- 3 pages, A4

--- A fresh unlisted buffer attached to `path`.
local function attached(path)
  reset_config { cell = { width = 10, height = 20 } }
  terminal.reset()
  local buf = vim.api.nvim_create_buf(false, true)
  local doc, err = viewer.attach(buf, path)
  ok(doc, tostring(err))
  return buf, doc
end

local function cleanup(buf)
  viewer.docs[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

describe('viewer.attach', function()
  it('registers an image document', function()
    local buf, doc = attached(PNG)
    eq('image', doc.kind)
    eq(1, doc.page)
    eq(1, doc.zoom)
    eq(viewer.get(buf), doc)
    cleanup(buf)
  end)

  it('registers a PDF and reads its page count', function()
    local buf, doc = attached(PDF)
    eq('pdf', doc.kind)
    eq(3, doc.pages)
    cleanup(buf)
  end)

  it('makes the buffer a non-file scratch buffer', function()
    local buf = attached(PNG)
    eq('nofile', vim.bo[buf].buftype)
    eq('inlineview', vim.bo[buf].filetype)
    falsy(vim.bo[buf].modifiable)
    cleanup(buf)
  end)

  it('rejects a file it cannot display', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local doc, err = viewer.attach(buf, FIXTURES .. '/gen.py')
    falsy(doc)
    contains(err, 'not a viewable')
    cleanup(buf)
  end)

  it('rejects a path that does not exist', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local doc, err = viewer.attach(buf, FIXTURES .. '/missing.png')
    falsy(doc)
    contains(err, 'no such file')
    cleanup(buf)
  end)

  it('installs its keymaps on the buffer', function()
    local buf = attached(PNG)
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    local lhs = vim.tbl_map(function(m) return m.lhs end, maps)
    for _, key in ipairs { 'q', 'n', 'p', '+', '-', '0', 'w', 'f' } do
      ok(vim.tbl_contains(lhs, key), 'missing keymap: ' .. key)
    end
    cleanup(buf)
  end)
end)

describe('viewer.frame for images', function()
  it('fits a landscape image into the window', function()
    local buf, doc = attached(PNG) -- 200x120 px = 20x6 cells
    local frame, err = viewer.frame(doc, 80, 20)
    ok(frame, tostring(err))
    eq(PNG, frame.path, 'images are sent to the terminal untouched')
    eq(20, frame.cols)
    eq(6, frame.rows)
    cleanup(buf)
  end)

  it('shrinks an image that is taller than the window', function()
    local buf, doc = attached(TALL) -- 60x400 px = 6x20 cells
    local frame = viewer.frame(doc, 80, 10)
    ok(frame.rows <= 10, 'must not exceed the window height')
    eq(3, frame.cols, 'aspect ratio preserved while halving the height')
    cleanup(buf)
  end)

  it('honours the zoom factor', function()
    local buf, doc = attached(PNG)
    doc.zoom = 2
    local frame = viewer.frame(doc, 80, 40)
    eq(40, frame.cols)
    eq(12, frame.rows)
    cleanup(buf)
  end)

  it('never overflows the window, however far it is zoomed', function()
    local buf, doc = attached(PNG)
    doc.zoom = 50
    local frame = viewer.frame(doc, 30, 8)
    ok(frame.cols <= 30 and frame.rows <= 8)
    cleanup(buf)
  end)

  it('surfaces an error for a corrupt image', function()
    local path = vim.fn.tempname() .. '.png'
    vim.fn.writefile({ 'not a png' }, path)
    local buf = vim.api.nvim_create_buf(false, true)
    local doc = viewer.attach(buf, path)
    local frame, err = viewer.frame(doc, 80, 20)
    falsy(frame)
    ok(err)
    cleanup(buf)
    os.remove(path)
  end)
end)

describe('viewer.frame for PDFs', function()
  it('rasterizes the page and returns a cached PNG, not the PDF', function()
    local buf, doc = attached(PDF)
    local frame, err = viewer.frame(doc, 80, 40)
    ok(frame, tostring(err))
    ne(PDF, frame.path)
    matches(frame.path, '%.png$')
    ok(vim.uv.fs_stat(frame.path))
    cleanup(buf)
  end)

  it('fills the window rather than sitting at natural size', function()
    local buf, doc = attached(PDF)
    local frame = viewer.frame(doc, 80, 40)
    -- A4 is taller than it is wide, so the height should bind.
    eq(40, frame.rows)
    ok(frame.cols <= 80)
    cleanup(buf)
  end)

  it('renders a different file for a different page', function()
    local buf, doc = attached(PDF)
    local first = viewer.frame(doc, 80, 40).path
    doc.page = 2
    local second = viewer.frame(doc, 80, 40).path
    ne(first, second)
    cleanup(buf)
  end)

  it('crops at a higher dpi instead of upscaling when zoomed', function()
    local buf, doc = attached(PDF)
    local base = viewer.frame(doc, 80, 40)
    doc.zoom = 3
    local zoomed = viewer.frame(doc, 80, 40)

    -- The visible area still fills the window exactly.
    eq(40, zoomed.rows)
    eq(40, base.rows)

    -- The cache file name encodes the dpi the page was rasterized at. Zooming
    -- 3x should raise it roughly 3x -- that is what makes small text sharper
    -- rather than merely bigger.
    local base_dpi = tonumber(base.path:match '/p%d+%-(%d+)')
    local zoom_dpi = tonumber(zoomed.path:match '/p%d+%-(%d+)')
    ok(base_dpi and zoom_dpi, 'could not read the dpi back out of the cache path')
    near(base_dpi * 3, zoom_dpi, base_dpi * 0.2, 'dpi should scale with zoom')

    -- And the crop itself stays about window-sized, confirming we rasterized
    -- a slice of a big page rather than enlarging the whole page.
    local imageinfo = require 'inlineview.imageinfo'
    local zoom_px = imageinfo.probe(zoomed.path)
    near(40 * 20, zoom_px.height, 30, 'crop height should track the window, not the page')
    cleanup(buf)
  end)

  it('clamps panning to the part of the page that is off-screen', function()
    local buf, doc = attached(PDF)
    doc.zoom = 2
    doc.pan = { x = 9999, y = 9999 }
    viewer.frame(doc, 80, 40)
    -- At zoom 2 the page is twice the window, so at most one window-worth
    -- can be scrolled past in each axis.
    ok(doc.pan.y > 0, 'should have panned somewhere')
    ok(doc.pan.y <= 40, 'pan must not exceed the hidden remainder: ' .. doc.pan.y)
    ok(doc.pan.x <= 80, 'pan must not exceed the hidden remainder: ' .. doc.pan.x)
    cleanup(buf)
  end)

  it('does not pan at all when the page already fits', function()
    local buf, doc = attached(PDF)
    doc.zoom = 1
    doc.pan = { x = 500, y = 500 }
    viewer.frame(doc, 80, 40)
    eq(0, doc.pan.x)
    eq(0, doc.pan.y)
    cleanup(buf)
  end)
end)

describe('viewer page navigation', function()
  it('steps forward and back', function()
    local buf, doc = attached(PDF)
    viewer.goto_page(buf, 1)
    eq(2, doc.page)
    viewer.goto_page(buf, 1)
    eq(3, doc.page)
    viewer.goto_page(buf, -1)
    eq(2, doc.page)
    cleanup(buf)
  end)

  it('stops at the first and last page', function()
    local buf, doc = attached(PDF)
    viewer.goto_page(buf, -10)
    eq(1, doc.page)
    viewer.goto_page(buf, 10)
    eq(3, doc.page)
    cleanup(buf)
  end)

  it('jumps to an absolute page', function()
    local buf, doc = attached(PDF)
    viewer.goto_page(buf, 3, true)
    eq(3, doc.page)
    viewer.goto_page(buf, 99, true)
    eq(3, doc.page, 'out-of-range jumps clamp')
    cleanup(buf)
  end)

  it('resets the pan when the page changes', function()
    local buf, doc = attached(PDF)
    doc.pan = { x = 5, y = 5 }
    viewer.goto_page(buf, 1)
    eq({ x = 0, y = 0 }, doc.pan)
    cleanup(buf)
  end)

  it('ignores paging for a plain image', function()
    local buf, doc = attached(PNG)
    viewer.goto_page(buf, 5)
    eq(1, doc.page)
    cleanup(buf)
  end)
end)

describe('viewer zoom and fit', function()
  it('multiplies and divides by the configured step', function()
    local buf, doc = attached(PNG)
    viewer.zoom(buf, 2)
    eq(2, doc.zoom)
    viewer.zoom(buf, 0.5)
    eq(1, doc.zoom)
    cleanup(buf)
  end)

  it('clamps to a sane range', function()
    local buf, doc = attached(PNG)
    for _ = 1, 40 do
      viewer.zoom(buf, 2)
    end
    ok(doc.zoom <= 20, 'got ' .. doc.zoom)
    for _ = 1, 80 do
      viewer.zoom(buf, 0.5)
    end
    ok(doc.zoom >= 0.1, 'got ' .. doc.zoom)
    cleanup(buf)
  end)

  it('resets zoom and pan together', function()
    local buf, doc = attached(PDF)
    doc.zoom = 4
    doc.pan = { x = 3, y = 3 }
    viewer.zoom_reset(buf)
    eq(1, doc.zoom)
    eq({ x = 0, y = 0 }, doc.pan)
    cleanup(buf)
  end)

  it('switches fit mode', function()
    local buf, doc = attached(PNG)
    viewer.set_fit(buf, 'width')
    eq('width', doc.fit)
    local frame = viewer.frame(doc, 40, 100)
    eq(40, frame.cols, 'fit=width should span the window')
    cleanup(buf)
  end)

  it('only pans PDFs', function()
    local buf, doc = attached(PNG)
    viewer.pan(buf, 5, 5)
    eq({ x = 0, y = 0 }, doc.pan)
    cleanup(buf)
  end)
end)

describe('viewer.open_float', function()
  it('creates a window and registers the document', function()
    reset_config()
    local buf, err = viewer.open_float(PNG)
    ok(buf, tostring(err))
    ok(viewer.get(buf))
    local win = vim.fn.bufwinid(buf)
    ne(-1, win)
    eq('editor', vim.api.nvim_win_get_config(win).relative)
    cleanup(buf)
  end)

  it('puts the file name and backend in the status line', function()
    reset_config()
    local buf = viewer.open_float(PDF)
    local win = vim.fn.bufwinid(buf)
    -- paint_win writes the status line as real buffer text.
    viewer.paint_win(win, buf, viewer.get(buf))
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    contains(first, 'sample.pdf')
    contains(first, 'page 1/3')
    cleanup(buf)
  end)

  it('pads the buffer to the window height so no ~ markers show', function()
    reset_config()
    local buf = viewer.open_float(PNG)
    local win = vim.fn.bufwinid(buf)
    viewer.paint_win(win, buf, viewer.get(buf))
    eq(vim.api.nvim_win_get_height(win), vim.api.nvim_buf_line_count(buf))
    cleanup(buf)
  end)

  it('reports an error without leaving a window behind', function()
    reset_config()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    local buf, err = viewer.open_float(FIXTURES .. '/missing.png')
    falsy(buf)
    ok(err)
    eq(before, #vim.api.nvim_tabpage_list_wins(0), 'the failed window must be cleaned up')
  end)
end)

describe('viewer painting', function()
  it('writes an image to the terminal for a visible document', function()
    reset_config { backend = 'iterm2' }
    terminal.reset()
    local buf = viewer.open_float(PNG)
    local win = vim.fn.bufwinid(buf)

    local out = capture_terminal(function() viewer.paint_win(win, buf, viewer.get(buf)) end)

    contains(out, '\27]1337;File=', 'an inline image should have been emitted')
    contains(out, 'inline=1')
    cleanup(buf)
    reset_config()
    terminal.reset()
  end)

  it('records a backend error in the status line instead of raising', function()
    reset_config { backend = 'none' }
    terminal.reset()
    local buf = viewer.open_float(PNG)
    local win = vim.fn.bufwinid(buf)
    viewer.paint_win(win, buf, viewer.get(buf))

    local doc = viewer.get(buf)
    ok(doc.err, 'an error should have been recorded')
    contains(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], 'ERROR')
    cleanup(buf)
    reset_config()
    terminal.reset()
  end)

  it('paints nothing when no document is visible', function()
    reset_config()
    local out = capture_terminal(function() viewer.paint_all() end)
    eq('', out)
  end)
end)

describe('viewer.detach', function()
  it('forgets the document', function()
    local buf = attached(PNG)
    viewer.detach(buf)
    falsy(viewer.get(buf))
    cleanup(buf)
  end)

  it('drops documents whose buffer was wiped', function()
    local buf = attached(PNG)
    vim.api.nvim_buf_delete(buf, { force = true })
    falsy(viewer.get(buf))
  end)
end)
