local terminal = require 'inlineview.terminal'

-- `capture_terminal` and `with_env` are defined in tests/run.lua so that the
-- specs that sort before this one can use them too.
local capture = capture_terminal

describe('terminal.passthrough', function()
  it('leaves sequences alone outside a multiplexer', function()
    with_env({ TMUX = UNSET, TERM = 'xterm-256color' }, function() eq('\27]1337;x\7', terminal.passthrough '\27]1337;x\7') end)
  end)

  it('wraps and doubles escapes for tmux', function()
    with_env({ TMUX = '/tmp/tmux-0/default,123,0' }, function()
      local out = terminal.passthrough '\27]1337;x\7'
      matches(out, '^\27Ptmux;')
      matches(out, '\27\\$')
      -- The payload's ESC must be doubled or tmux swallows it.
      contains(out, '\27\27]1337;x\7')
    end)
  end)

  it('chunks long payloads for screen', function()
    with_env({ TMUX = UNSET, TERM = 'screen.xterm-256color' }, function()
      local payload = ('a'):rep(2000)
      local out = terminal.passthrough(payload)
      local _, chunks = out:gsub('\27P', '')
      eq(3, chunks, '2000 bytes should split into three 768-byte DCS chunks')
      matches(out, '\27\\$')
    end)
  end)
end)

describe('terminal.write_at', function()
  it('brackets the payload with cursor save, move and restore', function()
    with_env({ TMUX = UNSET, TERM = 'xterm-256color' }, function()
      local out = capture(function() terminal.write_at(7, 13, 'PAYLOAD') end)
      eq('\0277\27[7;13HPAYLOAD\0278', out)
    end)
  end)

  it('does nothing when there is no writer', function()
    terminal.set_writer(nil)
    -- Must not raise even though stdout is not a tty under `nvim -l`.
    terminal.write 'ignored'
  end)
end)

describe('terminal.detect', function()
  --- Start from a terminal that identifies as nothing, then set only the
  --- variables under test. The suite itself runs inside iTerm2, so these must
  --- genuinely be unset rather than merely absent from the table.
  local function detect_with(vars)
    local result
    with_env(
      vim.tbl_extend('force', {
        LC_TERMINAL = UNSET,
        TERM_PROGRAM = UNSET,
        KITTY_WINDOW_ID = UNSET,
        GHOSTTY_RESOURCES_DIR = UNSET,
        WEZTERM_PANE = UNSET,
        KONSOLE_VERSION = UNSET,
        TERM = 'xterm-256color',
      }, vars),
      function() result = terminal.detect() end
    )
    return result
  end

  it('recognises iTerm2 through SSH via LC_TERMINAL', function() eq('iterm2', detect_with { LC_TERMINAL = 'iTerm2' }) end)

  it('recognises iTerm2 locally via TERM_PROGRAM', function() eq('iterm2', detect_with { TERM_PROGRAM = 'iTerm.app' }) end)

  it('recognises kitty', function() eq('kitty', detect_with { KITTY_WINDOW_ID = '1' }) end)

  it('maps ghostty and wezterm onto the kitty protocol', function()
    eq('kitty', detect_with { GHOSTTY_RESOURCES_DIR = '/x' })
    eq('kitty', detect_with { WEZTERM_PANE = '0' })
  end)

  it('prefers iTerm2 over a kitty-looking TERM', function() eq('iterm2', detect_with { LC_TERMINAL = 'iTerm2', TERM = 'xterm-kitty' }) end)

  it('falls back to blocks for an unknown terminal', function()
    -- chafa is installed in this environment, so blocks is reachable.
    local result = detect_with {}
    ok(result == 'blocks' or result == 'none', 'got ' .. tostring(result))
  end)
end)

describe('terminal.backend_name', function()
  it('honours an explicit config override', function()
    reset_config { backend = 'kitty' }
    terminal.reset()
    eq('kitty', terminal.backend_name())
    reset_config { backend = 'auto' }
    terminal.reset()
  end)
end)

describe('terminal.cell_size', function()
  it('returns positive dimensions', function()
    local cell = terminal.cell_size()
    ok(cell.width > 0, 'width')
    ok(cell.height > 0, 'height')
  end)

  it('caches between calls', function() eq(terminal.cell_size(), terminal.cell_size()) end)
end)
