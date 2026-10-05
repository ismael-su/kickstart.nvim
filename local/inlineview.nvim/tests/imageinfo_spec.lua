local imageinfo = require 'inlineview.imageinfo'

local function fixture(name) return FIXTURES .. '/' .. name end

describe('imageinfo.probe', function()
  --- Every expectation here is the size the fixture was generated at, so a
  --- parser that merely returns plausible numbers still fails.
  local cases = {
    { 'gradient.png', 200, 120, 'png' },
    { 'tall.png', 60, 400, 'png' },
    { 'tiny.png', 4, 4, 'png' },
    { 'page1.jpg', 166, 234, 'jpeg' },
    { 'dot.gif', 32, 24, 'gif' },
    { 'block.bmp', 16, 9, 'bmp' },
    { 'lossless.webp', 300, 200, 'webp' },
    { 'extended.webp', 640, 480, 'webp' },
  }

  for _, case in ipairs(cases) do
    local name, w, h, format = unpack(case)
    it(('reads %s as %dx%d'):format(name, w, h), function()
      local info, err = imageinfo.probe(fixture(name))
      ok(info, 'probe failed: ' .. tostring(err))
      eq(w, info.width, 'width')
      eq(h, info.height, 'height')
      eq(format, info.format, 'format')
    end)
  end

  it('reports an error for a missing file', function()
    local info, err = imageinfo.probe(fixture 'does-not-exist.png')
    falsy(info)
    ok(err)
  end)

  it('reports an error for a file that is not an image', function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ 'this is plain text, not an image at all' }, path)
    local info, err = imageinfo.probe(path)
    falsy(info)
    contains(err, 'unsupported')
    os.remove(path)
  end)

  it('rejects a truncated PNG rather than returning garbage', function()
    local path = vim.fn.tempname() .. '.png'
    local full = io.open(fixture 'gradient.png', 'rb'):read '*a'
    local f = io.open(path, 'wb')
    f:write(full:sub(1, 10)) -- signature only, no IHDR
    f:close()
    local info = imageinfo.probe(path)
    falsy(info)
    os.remove(path)
  end)
end)

describe('imageinfo format sniffing', function()
  --- Detection is by magic bytes, so a mislabelled extension still works.
  it('identifies a PNG whose extension lies', function()
    local path = vim.fn.tempname() .. '.jpg'
    local data = io.open(fixture 'gradient.png', 'rb'):read '*a'
    local f = io.open(path, 'wb')
    f:write(data)
    f:close()
    local info = imageinfo.probe(path)
    ok(info)
    eq('png', info.format)
    eq(200, info.width)
    os.remove(path)
  end)

  it('distinguishes the three WebP sub-formats', function()
    local lossless = imageinfo.probe(fixture 'lossless.webp')
    local extended = imageinfo.probe(fixture 'extended.webp')
    eq(300, lossless.width)
    eq(640, extended.width)
  end)
end)
