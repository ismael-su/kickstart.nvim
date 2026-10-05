--- `:checkhealth inlineview`
local M = {}

local function report_terminal()
  local terminal = require 'inlineview.terminal'
  vim.health.start 'inlineview: terminal'

  local detected = terminal.detect()
  local active = terminal.backend_name()

  if detected == 'iterm2' then
    vim.health.ok(('iTerm2 detected (LC_TERMINAL=%s %s)'):format(vim.env.LC_TERMINAL, vim.env.LC_TERMINAL_VERSION or ''))
  elseif detected == 'kitty' then
    vim.health.ok 'Kitty graphics protocol detected'
  elseif detected == 'blocks' then
    vim.health.warn('no graphics protocol detected; falling back to Unicode half-blocks', {
      'Images will be approximated with coloured text.',
      'For true pixels use iTerm2, Kitty, Ghostty or WezTerm.',
    })
  else
    vim.health.error('no usable backend', {
      'Install chafa for a text-based fallback, or use a terminal with an image protocol.',
    })
  end

  if active ~= detected then vim.health.info(('backend overridden by config: %s'):format(active)) end

  if terminal.has_writer() then
    vim.health.ok 'terminal is writable'
  else
    vim.health.error 'cannot open the terminal for writing; images cannot be drawn'
  end

  local cell = terminal.cell_size()
  local defaults = require('inlineview.config').defaults.cell
  if cell.width == defaults.width and cell.height == defaults.height then
    vim.health.warn(('cell size probe failed; using the configured %dx%d px'):format(cell.width, cell.height), {
      'Images may be stretched. Set `cell = { width = W, height = H }` to correct it.',
      'The probe needs python3 and a readable /dev/tty.',
    })
  else
    vim.health.ok(('cell size: %dx%d px'):format(cell.width, cell.height))
  end

  if vim.env.TMUX and vim.env.TMUX ~= '' then
    local res = vim.system({ 'tmux', 'show', '-Apv', 'allow-passthrough' }, { text = true }):wait(2000)
    local value = ((res.stdout or ''):gsub('%s+$', ''))
    if value == 'on' or value == 'all' then
      vim.health.ok 'tmux allow-passthrough is on'
    else
      vim.health.error('tmux is active but allow-passthrough is off', {
        'Add to tmux.conf:  set -g allow-passthrough on',
      })
    end
  end
end

local function report_tools()
  vim.health.start 'inlineview: external tools'

  local ok, err = require('inlineview.pdf').available()
  if ok then
    vim.health.ok 'poppler found (pdfinfo, pdftoppm) -- PDF viewing enabled'
  else
    vim.health.warn('PDF viewing disabled: ' .. err, {
      'Install poppler-utils (Debian/Ubuntu) or poppler (macOS, Arch).',
    })
  end

  if vim.fn.executable 'chafa' == 1 then
    vim.health.ok 'chafa found -- half-block fallback available'
  else
    vim.health.info 'chafa not found; no fallback for terminals without an image protocol'
  end

  if vim.fn.executable 'python3' == 1 then
    vim.health.ok 'python3 found -- cell size can be probed'
  else
    vim.health.warn 'python3 not found; cell size falls back to the configured default'
  end

  if vim.base64 and vim.base64.encode then
    vim.health.ok 'vim.base64 available'
  else
    vim.health.error 'vim.base64 missing; Neovim 0.10+ is required'
  end
end

function M.check()
  report_terminal()
  report_tools()
end

return M
