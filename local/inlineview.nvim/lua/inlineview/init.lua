--- inlineview.nvim -- view images and PDFs inside Neovim.
---
--- Public entry point: `setup()`, the commands, and the autocmds that keep
--- images painted as the screen changes.
local config = require 'inlineview.config'
local inline = require 'inlineview.inline'
local terminal = require 'inlineview.terminal'
local util = require 'inlineview.util'
local viewer = require 'inlineview.viewer'

local M = {}

M.config = config
M.viewer = viewer
M.inline = inline

local bootstrapped = false
local group = nil

--------------------------------------------------------------------------
-- Autocmds
--------------------------------------------------------------------------

--- Glob patterns for every extension we can display.
---@return string[]
local function file_patterns()
  local patterns = {}
  for _, list in pairs(config.options.filetypes) do
    for _, ext in ipairs(list) do
      patterns[#patterns + 1] = '*.' .. ext
      patterns[#patterns + 1] = '*.' .. ext:upper()
    end
  end
  return patterns
end

--- Load `path` into `buf` as ordinary text.
---
--- `BufReadCmd` takes over the read completely and Neovim will not fall back
--- on its own, so declining to display a file makes us responsible for
--- loading it. Without this the user gets a silently empty buffer.
---@param buf integer
---@param path string
local function read_fallback(buf, path)
  vim.bo[buf].buftype = ''
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, ('keepalt noautocmd silent! read ++edit %s'):format(vim.fn.fnameescape(path)))
    pcall(vim.cmd, 'silent! 1delete _') -- drop the blank line `read` leaves behind
  end)
  vim.bo[buf].modified = false
end

local function create_autocmds()
  group = vim.api.nvim_create_augroup('inlineview', { clear = true })

  local function au(event, opts)
    opts.group = group
    vim.api.nvim_create_autocmd(event, opts)
  end

  -- Intercept the read so Neovim never loads binary content into the buffer.
  --
  -- The callback must not return a truthy value: |nvim_create_autocmd|
  -- deletes any callback that returns true, which would make each extension
  -- display correctly exactly once per session and show raw bytes after that.
  if config.options.auto_open then
    au('BufReadCmd', {
      pattern = file_patterns(),
      callback = function(ev)
        local ok, err = viewer.open_in_buffer(ev.buf, ev.match)
        if not ok then
          util.warn(err or 'cannot open')
          read_fallback(ev.buf, ev.match)
        end
      end,
      desc = 'inlineview: display images/PDFs instead of reading them',
    })
  end

  -- Anything that may have scrolled or resized the image out of place.
  au({ 'WinScrolled', 'WinResized', 'TabEnter', 'FocusGained', 'CmdlineLeave', 'BufWinEnter', 'WinEnter' }, {
    callback = function() M.refresh() end,
    desc = 'inlineview: repaint after screen changes',
  })

  -- A font or window size change invalidates the probed cell geometry.
  au('VimResized', {
    callback = function()
      terminal.reset()
      M.refresh()
    end,
    desc = 'inlineview: re-probe cell size and repaint',
  })

  au({ 'BufWipeout', 'BufDelete' }, {
    callback = function(ev)
      if viewer.get(ev.buf) then viewer.detach(ev.buf) end
      inline.enabled[ev.buf] = nil
    end,
    desc = 'inlineview: release documents',
  })

  au('WinClosed', {
    callback = function() viewer.clear_all() end,
    desc = 'inlineview: erase stale images',
  })

  au('FileType', {
    callback = function(ev)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then inline.maybe_enable(ev.buf) end
      end)
    end,
    desc = 'inlineview: enable inline rendering for prose filetypes',
  })

  au({ 'TextChanged', 'InsertLeave' }, {
    callback = function(ev)
      if inline.enabled[ev.buf] then M.refresh() end
    end,
    desc = 'inlineview: re-render inline links after edits',
  })

  au('VimLeavePre', {
    callback = function() require('inlineview.backends').clear_all() end,
    desc = 'inlineview: clean up on exit',
  })
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------

local function create_commands()
  local function cmd(name, fn, opts) vim.api.nvim_create_user_command(name, fn, opts or {}) end

  cmd('InlineView', function(args)
    local path = args.args ~= '' and args.args or vim.api.nvim_buf_get_name(0)
    if path == '' then return util.err 'no file given and the current buffer has no name' end
    local _, err = viewer.open_float(vim.fn.expand(path))
    if err then util.err(err) end
  end, {
    nargs = '?',
    complete = 'file',
    desc = 'View an image or PDF in a floating window',
  })

  cmd('InlineViewClose', function()
    local buf = vim.api.nvim_get_current_buf()
    if viewer.get(buf) then
      viewer.close(buf)
    else
      util.warn 'not an inlineview buffer'
    end
  end, { desc = 'Close the current inlineview buffer' })

  cmd('InlineViewRefresh', function()
    terminal.reset()
    M.refresh { erase = true }
  end, { desc = 'Re-probe the terminal and repaint everything' })

  cmd('InlineViewClear', function()
    require('inlineview.backends').clear_all()
    vim.schedule(function() pcall(vim.cmd, 'redraw!') end)
  end, { desc = 'Erase all images drawn by inlineview' })

  cmd('InlineViewInline', function()
    local on = inline.toggle(vim.api.nvim_get_current_buf())
    util.notify('inline rendering ' .. (on and 'enabled' or 'disabled'))
  end, { desc = 'Toggle in-buffer rendering of image links' })

  cmd('InlineViewInfo', function()
    local cell = terminal.cell_size()
    local lines = {
      'backend:    ' .. terminal.backend_name(),
      'detected:   ' .. terminal.detect(),
      'cell size:  ' .. string.format('%dx%d px', cell.width, cell.height),
      'screen:     ' .. string.format('%dx%d cells', vim.o.columns, vim.o.lines),
      'writer:     ' .. tostring(terminal.has_writer()),
      'LC_TERMINAL: ' .. tostring(vim.env.LC_TERMINAL),
      'TMUX:       ' .. tostring(vim.env.TMUX ~= nil and vim.env.TMUX ~= ''),
    }
    util.notify('\n' .. table.concat(lines, '\n'))
  end, { desc = 'Show detected terminal capabilities' })
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

local refresh_debounced = nil

--- Repaint documents and inline images, coalescing bursts of events.
---@param opts {erase: boolean|nil}|nil
function M.refresh(opts)
  if opts and opts.erase then
    viewer.paint_all { erase = true }
    inline.render_all()
    return
  end
  if not refresh_debounced then refresh_debounced = util.debounce(config.options.debounce, function()
    viewer.paint_all()
    inline.render_all()
  end) end
  refresh_debounced()
end

--- Register commands and autocmds. Idempotent; safe to call from `plugin/`
--- and again from a user's `setup()`.
function M.bootstrap()
  if bootstrapped then return end
  bootstrapped = true
  create_commands()
  create_autocmds()
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  -- Rebuild the debouncer so a configured interval takes effect.
  refresh_debounced = util.debounce(config.options.debounce, function()
    viewer.paint_all()
    inline.render_all()
  end)
  if bootstrapped then
    -- Re-register so BufReadCmd patterns track a changed filetype list.
    create_autocmds()
  else
    M.bootstrap()
  end
  return M
end

--- Open `path` in a floating viewer.
---@param path string
function M.open(path) return viewer.open_float(vim.fn.expand(path)) end

return M
