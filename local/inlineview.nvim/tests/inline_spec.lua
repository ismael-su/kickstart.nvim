local inline = require 'inlineview.inline'

--- A buffer whose "file" lives in the fixtures directory, so relative links
--- resolve the way they would in a real document.
---@param lines string[]
---@return integer
local function doc_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, FIXTURES .. '/notes.md')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  return buf
end

local function links_of(lines)
  local buf = doc_buffer(lines)
  local found = inline.find_links(buf, 1, #lines)
  vim.api.nvim_buf_delete(buf, { force = true })
  return found
end

describe('inline.find_links', function()
  it('finds a markdown image link', function()
    local found = links_of { '# Title', '', '![a diagram](gradient.png)', '' }
    eq(1, #found)
    eq(3, found[1].lnum)
    eq('image', found[1].kind)
    matches(found[1].path, 'gradient%.png$')
  end)

  it('finds several links across the buffer', function()
    local found = links_of {
      '![one](gradient.png)',
      'prose in between',
      '![two](tall.png)',
    }
    eq(2, #found)
    eq(1, found[1].lnum)
    eq(3, found[2].lnum)
  end)

  it('treats a linked PDF as a document to rasterize', function()
    local found = links_of { '![spec](sample.pdf)' }
    eq(1, #found)
    eq('pdf', found[1].kind)
  end)

  it('understands org-style file links', function()
    local found = links_of { '[[file:gradient.png]]' }
    eq(1, #found)
    matches(found[1].path, 'gradient%.png$')
  end)

  it('understands html img tags', function()
    local found = links_of { '<img src="gradient.png" width="40">' }
    eq(1, #found)
    matches(found[1].path, 'gradient%.png$')
  end)

  it('strips a markdown title from the path', function()
    local found = links_of { '![x](gradient.png "A caption here")' }
    eq(1, #found)
    matches(found[1].path, 'gradient%.png$')
  end)

  it('handles angle-bracketed paths', function()
    local found = links_of { '![x](<gradient.png>)' }
    eq(1, #found)
    matches(found[1].path, 'gradient%.png$')
  end)

  it('resolves an absolute path', function()
    local found = links_of { ('![x](%s/gradient.png)'):format(FIXTURES) }
    eq(1, #found)
  end)

  it('skips remote URLs', function()
    local found = links_of {
      '![remote](https://example.com/a.png)',
      '![remote](http://example.com/b.png)',
    }
    eq(0, #found)
  end)

  it('skips links whose target is missing', function() eq(0, #links_of { '![gone](no-such-image.png)' }) end)

  it('skips links to files that are not images', function() eq(0, #links_of { '![script](gen.py)' }) end)

  it('ignores a plain markdown link, which is not an image', function() eq(0, #links_of { '[not an image](gradient.png)' }) end)

  it('only scans the requested range', function()
    local buf = doc_buffer { '![a](gradient.png)', 'text', '![b](tall.png)' }
    eq(1, #inline.find_links(buf, 1, 1))
    eq(1, #inline.find_links(buf, 3, 3))
    eq(0, #inline.find_links(buf, 2, 2))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('clamps a range that runs past the end of the buffer', function()
    local buf = doc_buffer { '![a](gradient.png)' }
    eq(1, #inline.find_links(buf, -50, 500))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe('inline rendering', function()
  it('reserves virtual lines for each image', function()
    reset_config()
    local buf = doc_buffer { '# Notes', '', '![a](gradient.png)', '', 'more text' }
    inline.enabled[buf] = true

    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 60,
      height = 20,
      row = 1,
      col = 1,
    })

    capture_terminal(function() inline.render_win(win) end)

    local ns = vim.api.nvim_get_namespaces()['inlineview_inline']
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(1, #marks, 'one extmark for one image')
    eq(2, marks[1][2], 'anchored to the link line (0-based)')
    ok(marks[1][4].virt_lines, 'virtual lines should reserve the space')
    ok(#marks[1][4].virt_lines > 0)

    pcall(vim.api.nvim_win_close, win, true)
    inline.enabled[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('removes its extmarks when toggled off', function()
    reset_config()
    local buf = doc_buffer { '![a](gradient.png)' }
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 60,
      height = 20,
      row = 1,
      col = 1,
    })

    inline.enabled[buf] = true
    capture_terminal(function() inline.render_win(win) end)

    local ns = vim.api.nvim_get_namespaces()['inlineview_inline']
    ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0)

    inline.clear(buf)
    eq(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))

    pcall(vim.api.nvim_win_close, win, true)
    inline.enabled[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('does nothing for a buffer that is not enabled', function()
    reset_config()
    local buf = doc_buffer { '![a](gradient.png)' }
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 60,
      height = 20,
      row = 1,
      col = 1,
    })

    local out = capture_terminal(function() inline.render_win(win) end)
    eq('', out)

    pcall(vim.api.nvim_win_close, win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('enables itself for a configured filetype', function()
    reset_config { inline = { enabled = true, filetypes = { 'markdown' } } }
    local buf = doc_buffer { 'no images here' }
    inline.maybe_enable(buf)
    ok(inline.enabled[buf])
    inline.enabled[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('stays out of the way for other filetypes', function()
    reset_config { inline = { enabled = true, filetypes = { 'markdown' } } }
    local buf = doc_buffer { 'x' }
    vim.bo[buf].filetype = 'lua'
    inline.maybe_enable(buf)
    falsy(inline.enabled[buf])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('respects inline.enabled = false', function()
    reset_config { inline = { enabled = false, filetypes = { 'markdown' } } }
    local buf = doc_buffer { 'x' }
    inline.maybe_enable(buf)
    falsy(inline.enabled[buf])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
