describe('config.ext and config.kind', function()
  local config = reset_config()

  it('lowercases the extension', function()
    eq('png', config.ext '/tmp/A.PNG')
    eq('pdf', config.ext 'report.PDF')
  end)

  it('returns an empty string when there is no extension', function() eq('', config.ext '/tmp/README') end)

  it('classifies images and PDFs', function()
    eq('image', config.kind 'a.png')
    eq('image', config.kind 'a.JPEG')
    eq('pdf', config.kind 'a.pdf')
  end)

  it('returns nil for anything else', function()
    falsy(config.kind 'a.lua')
    falsy(config.kind 'Makefile')
  end)
end)

describe('config.setup', function()
  it('merges nested options without discarding the rest', function()
    local config = reset_config { pdf = { max_dpi = 123 } }
    eq(123, config.options.pdf.max_dpi)
    eq(config.defaults.pdf.min_dpi, config.options.pdf.min_dpi, 'untouched keys survive')
  end)

  it('replaces list options instead of merging them element-wise', function()
    -- The usual deep-merge trap: a shorter user list must not leave the tail
    -- of the default list in place.
    local config = reset_config { filetypes = { image = { 'png' } } }
    eq({ 'png' }, config.options.filetypes.image)
  end)

  it('replaces the inline filetype list too', function()
    local config = reset_config { inline = { filetypes = { 'markdown' } } }
    eq({ 'markdown' }, config.options.inline.filetypes)
  end)

  it('leaves defaults intact when called with nothing', function()
    local config = reset_config()
    eq(config.defaults.fit, config.options.fit)
    eq(config.defaults.filetypes.image, config.options.filetypes.image)
  end)

  it('does not mutate the defaults table', function()
    local config = reset_config { fit = 'width', filetypes = { pdf = { 'xyz' } } }
    eq('contain', config.defaults.fit)
    eq({ 'pdf' }, config.defaults.filetypes.pdf)
  end)
end)

describe('plugin surface', function()
  -- The suite above deliberately narrows the filetype lists, and BufReadCmd
  -- patterns are derived from them. Go through the real `setup()` so both the
  -- config and the autocmds are back at their defaults.
  require('inlineview').setup {}

  it('exposes setup and the submodules', function()
    local inlineview = require 'inlineview'
    eq('function', type(inlineview.setup))
    eq('function', type(inlineview.open))
    eq('function', type(inlineview.refresh))
    ok(inlineview.viewer)
    ok(inlineview.inline)
  end)

  it('registers its user commands on bootstrap', function()
    require('inlineview').bootstrap()
    local commands = vim.api.nvim_get_commands {}
    for _, name in ipairs {
      'InlineView',
      'InlineViewClose',
      'InlineViewRefresh',
      'InlineViewClear',
      'InlineViewInline',
      'InlineViewInfo',
    } do
      ok(commands[name], 'missing command: ' .. name)
    end
  end)

  it('registers a BufReadCmd so binary files are never loaded as text', function()
    require('inlineview').bootstrap()
    local autocmds = vim.api.nvim_get_autocmds { group = 'inlineview', event = 'BufReadCmd' }
    ok(#autocmds > 0)
    local patterns = vim.tbl_map(function(a) return a.pattern end, autocmds)
    ok(vim.tbl_contains(patterns, '*.png'), 'png not intercepted')
    ok(vim.tbl_contains(patterns, '*.pdf'), 'pdf not intercepted')
  end)

  it('is idempotent across repeated setup calls', function()
    local inlineview = require 'inlineview'
    inlineview.setup { fit = 'width' }
    inlineview.setup { fit = 'contain' }
    eq('contain', require('inlineview.config').options.fit)
    -- Autocmds are recreated with clear=true, so there should be no duplicates.
    local reads = vim.api.nvim_get_autocmds { group = 'inlineview', event = 'BufReadCmd' }
    local png = vim.tbl_filter(function(a) return a.pattern == '*.png' end, reads)
    eq(1, #png, 'duplicate BufReadCmd handlers for *.png')
  end)
end)

describe('health check', function()
  it('runs without raising', function()
    local health = require 'inlineview.health'
    -- vim.health only exists inside :checkhealth, so stub the reporters.
    local saved = vim.health
    local calls = 0
    vim.health = setmetatable({}, {
      __index = function()
        return function() calls = calls + 1 end
      end,
    })
    local called_ok, err = pcall(health.check)
    vim.health = saved
    ok(called_ok, tostring(err))
    ok(calls > 0, 'the health check reported nothing')
  end)
end)
