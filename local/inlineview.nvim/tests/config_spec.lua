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

  --- Regression: the handler used to `return true`, and |nvim_create_autocmd|
  --- deletes any callback that returns true. Each extension therefore
  --- displayed correctly exactly once per session and showed raw bytes after
  --- that. A per-file test could never catch it -- it needs one session that
  --- opens several files.
  it('keeps its BufReadCmd handlers after displaying files', function()
    require('inlineview').setup {}
    local function count() return #vim.api.nvim_get_autocmds { group = 'inlineview', event = 'BufReadCmd' } end

    local before = count()
    ok(before > 0, 'no BufReadCmd handlers registered')

    local bufs = {}
    for _, name in ipairs { 'gradient.png', 'tall.png', 'tiny.png', 'sample.pdf' } do
      vim.cmd('edit ' .. vim.fn.fnameescape(FIXTURES .. '/' .. name))
      local buf = vim.api.nvim_get_current_buf()
      bufs[#bufs + 1] = buf
      eq(before, count(), 'handlers must survive opening ' .. name)
      ok(require('inlineview.viewer').get(buf), name .. ' was not displayed')
      eq('nofile', vim.bo[buf].buftype, name .. ' was loaded as text')
    end

    -- Re-open the first extension a second time: this is what actually broke.
    vim.cmd('edit ' .. vim.fn.fnameescape(FIXTURES .. '/gradient.png'))
    local again = vim.api.nvim_get_current_buf()
    ok(require('inlineview.viewer').get(again), 'the second PNG fell back to raw bytes')

    vim.cmd 'enew'
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
  end)

  it('loads the file as text rather than nothing when auto_open is off', function()
    -- BufReadCmd swallows the read, so opting out must still produce content.
    require('inlineview').setup { auto_open = false }
    eq(0, #vim.api.nvim_get_autocmds { group = 'inlineview', event = 'BufReadCmd' })

    vim.cmd('edit ' .. vim.fn.fnameescape(FIXTURES .. '/gradient.png'))
    local buf = vim.api.nvim_get_current_buf()
    falsy(require('inlineview.viewer').get(buf), 'should not have been displayed')
    ok(vim.api.nvim_buf_line_count(buf) > 0, 'buffer must not be empty')

    vim.cmd 'enew'
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    require('inlineview').setup {}
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
