local backends = require 'inlineview.backends'
local iterm2 = require 'inlineview.backends.iterm2'
local kitty = require 'inlineview.backends.kitty'
local terminal = require 'inlineview.terminal'

local PNG = FIXTURES .. '/gradient.png'

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local data = f:read '*a'
  f:close()
  return data
end

--- Pull the base64 payload out of an OSC 1337 sequence. The argument list is
--- base64 too, but base64 never contains ':', so the first one separates them.
local function payload_of(seq) return seq:match 'File=[^:]*:([A-Za-z0-9+/=]+)\7' end

describe('iterm2 backend', function()
  local saved_lines

  local function setup()
    saved_lines = vim.o.lines
    vim.o.lines = 50
  end

  local function teardown() vim.o.lines = saved_lines end

  it('emits a well-formed OSC 1337 inline image', function()
    setup()
    local out = capture_terminal(function()
      with_env({ TMUX = UNSET, TERM = 'xterm-256color' }, function() ok(iterm2.draw { path = PNG, row = 4, col = 9, cols = 20, rows = 10 }) end)
    end)
    teardown()

    contains(out, '\0277', 'cursor save')
    contains(out, '\27[4;9H', 'cursor positioning')
    contains(out, '\27]1337;File=', 'OSC 1337 introducer')
    contains(out, 'inline=1')
    contains(out, 'width=20')
    contains(out, 'height=10')
    contains(out, 'preserveAspectRatio=1')
    contains(out, 'size=' .. #read(PNG), 'byte count must match the payload')
    matches(out, '\0278$', 'cursor restore must come last')
  end)

  it('sends the exact file bytes, base64 encoded', function()
    setup()
    local out = capture_terminal(function() iterm2.draw { path = PNG, row = 2, col = 2, cols = 10, rows = 5 } end)
    teardown()

    local encoded = payload_of(out)
    ok(encoded, 'no payload found')
    eq(read(PNG), vim.base64.decode(encoded), 'decoded payload must equal the file')
  end)

  it('encodes the file name so iTerm2 can label the image', function()
    setup()
    local out = capture_terminal(function() iterm2.draw { path = PNG, row = 2, col = 2, cols = 10, rows = 5 } end)
    teardown()
    local name = out:match 'name=([A-Za-z0-9+/=]+)'
    ok(name)
    eq('gradient.png', vim.base64.decode(name))
  end)

  it('shortens an image that would reach the bottom row', function()
    -- Drawing into the last row makes the terminal scroll, which would shift
    -- Neovim's screen without Neovim knowing.
    saved_lines = vim.o.lines
    vim.o.lines = 24
    local out = capture_terminal(function() iterm2.draw { path = PNG, row = 20, col = 1, cols = 10, rows = 10 } end)
    vim.o.lines = saved_lines

    contains(out, 'height=4', 'rows should be clamped to lines-1 (23) minus row 20, plus 1')
    not_contains(out, 'height=10')
  end)

  it('refuses to draw when there is no vertical room', function()
    saved_lines = vim.o.lines
    vim.o.lines = 24
    local okd, err = iterm2.draw { path = PNG, row = 24, col = 1, cols = 10, rows = 4 }
    vim.o.lines = saved_lines
    falsy(okd)
    contains(err, 'no room')
  end)

  it('reports an unreadable file instead of raising', function()
    local okd, err = iterm2.draw { path = '/nope/missing.png', row = 1, col = 1, cols = 4, rows = 4 }
    falsy(okd)
    ok(err)
  end)

  it('claims support for every format, since iTerm2 decodes them', function()
    ok(iterm2.supports_path(FIXTURES .. '/page1.jpg'))
    ok(iterm2.supports_path(PNG))
  end)
end)

describe('kitty backend', function()
  it('only claims PNG, which is all the protocol decodes', function()
    ok(kitty.supports_path(PNG))
    falsy(kitty.supports_path(FIXTURES .. '/page1.jpg'))
  end)

  it('chunks the payload and marks continuation correctly', function()
    local out = capture_terminal(function()
      with_env({ TMUX = UNSET, TERM = 'xterm-kitty' }, function() ok(kitty.draw { path = PNG, row = 3, col = 5, cols = 20, rows = 10, id = 42 }) end)
    end)

    contains(out, 'a=T,f=100,i=42,c=20,r=10,C=1,q=2,m=1', 'first chunk header')
    local _, chunks = out:gsub('\27_G', '')
    local expected = math.ceil(#vim.base64.encode(read(PNG)) / 4096)
    eq(expected, chunks, 'one escape per 4096-byte base64 chunk')

    -- Every chunk but the last must say "more follows".
    local _, more = out:gsub('m=1', '')
    eq(expected - 1, more)
    contains(out, 'm=0', 'final chunk must terminate the transmission')
  end)

  it('deletes by image id', function()
    local out = capture_terminal(function() kitty.draw { path = PNG, row = 1, col = 1, cols = 4, rows = 4, id = 7 } end)
    ok(#out > 0)

    local del = capture_terminal(function() kitty.clear(7) end)
    contains(del, 'a=d,d=i,i=7')
  end)
end)

describe('backends.resolve', function()
  it('returns the iterm2 backend when iTerm2 is detected', function()
    reset_config { backend = 'auto' }
    with_env({ LC_TERMINAL = 'iTerm2' }, function()
      terminal.set_writer(function() end)
      local backend = backends.resolve(PNG)
      ok(backend)
      eq('iterm2', backend.name)
      terminal.set_writer(nil)
    end)
  end)

  it('falls back to blocks when the backend cannot decode the format', function()
    -- Kitty cannot display a JPEG, so a JPEG must not simply fail.
    reset_config { backend = 'kitty' }
    terminal.reset()
    terminal.set_writer(function() end)
    local backend, err = backends.resolve(FIXTURES .. '/page1.jpg')
    terminal.set_writer(nil)
    if vim.fn.executable 'chafa' == 1 then
      ok(backend, tostring(err))
      eq('blocks', backend.name)
    else
      falsy(backend)
    end
    reset_config { backend = 'auto' }
    terminal.reset()
  end)

  it('reports a clear error when no protocol is available', function()
    reset_config { backend = 'none' }
    terminal.reset()
    local backend, err = backends.resolve(PNG)
    falsy(backend)
    ok(err)
    reset_config { backend = 'auto' }
    terminal.reset()
  end)
end)

describe('blocks backend', function()
  local blocks = require 'inlineview.backends.blocks'

  it('renders coloured text positioned row by row', function()
    if vim.fn.executable 'chafa' ~= 1 then return end
    local saved = vim.o.lines
    vim.o.lines = 50
    local out = capture_terminal(function()
      with_env({ TMUX = UNSET, TERM = 'xterm-256color' }, function() ok(blocks.draw { path = PNG, row = 5, col = 2, cols = 20, rows = 10 }) end)
    end)
    vim.o.lines = saved

    contains(out, '\27[5;2H', 'first row positioned absolutely')
    contains(out, '\27[6;2H', 'second row positioned absolutely')
    contains(out, '\27[0m', 'colours reset so they do not bleed')
    matches(out, '\0278$')
  end)
end)
