--- User configuration and defaults.
local M = {}

---@class InlineView.Config
M.defaults = {
  --- "auto" picks the best backend the terminal admits to supporting.
  --- Force one of "iterm2" | "kitty" | "blocks" | "none" to override detection.
  backend = 'auto',

  --- Fraction of the editor used by the floating viewer.
  width = 0.9,
  height = 0.9,

  --- How the image is scaled into the viewer window.
  ---   "contain"  fit inside, never enlarge past 1:1
  ---   "fit"      fit inside, enlarging small images to fill
  ---   "width"    match the window width
  ---   "height"   match the window height
  ---   "original" 1:1 pixels
  fit = 'contain',

  --- Multiplied on top of `fit`. Changed at runtime by the zoom keymaps.
  zoom_step = 1.25,

  --- Terminal cell size in pixels. Left nil, it is probed from the tty via
  --- TIOCGWINSZ and only falls back to these numbers if the probe fails.
  cell = { width = 7, height = 15 },

  pdf = {
    --- Pages are rasterized to match the viewer size; dpi is clamped here.
    min_dpi = 36,
    max_dpi = 400,
    --- Render this many pages ahead in the background.
    prefetch = 1,
  },

  --- Open the viewer automatically when a binary image/PDF is edited, so that
  --- `nvim diagram.png` and `gf` onto a PDF just work.
  auto_open = true,

  filetypes = {
    image = { 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'avif', 'tiff', 'tif', 'ico' },
    pdf = { 'pdf' },
  },

  --- In-buffer rendering of image links (markdown `![](path)` and friends).
  inline = {
    enabled = true,
    filetypes = { 'markdown', 'vimwiki', 'rmd', 'quarto', 'norg', 'org' },
    --- Hard ceiling on the rows a single inline image may reserve.
    max_rows = 20,
    --- Only paint links within this many lines of the viewport.
    render_margin = 20,
  },

  --- Milliseconds to coalesce repaints after scrolling/resizing.
  debounce = 40,

  keymaps = {
    --- Set to false to skip installing viewer keymaps entirely.
    enabled = true,
    close = { 'q', '<Esc>' },
    next_page = { 'n', '<C-n>', '<PageDown>' },
    prev_page = { 'p', '<C-p>', '<PageUp>' },
    first_page = 'gg',
    last_page = 'G',
    zoom_in = { '+', '=' },
    zoom_out = { '-', '_' },
    zoom_reset = '0',
    fit_width = 'w',
    fit_contain = 'f',
    refresh = '<C-l>',
    help = '?',
  },
}

---@type InlineView.Config
M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  -- tbl_deep_extend merges list-like values key-by-key, which mangles the
  -- extension and keymap lists when a user supplies a shorter one. Replace
  -- those wholesale instead.
  local function replace_list(dst, src, path)
    local node = src
    for _, key in ipairs(path) do
      node = node and node[key]
    end
    if type(node) ~= 'table' then return end
    local target = dst
    for i = 1, #path - 1 do
      target = target[path[i]]
    end
    target[path[#path]] = vim.deepcopy(node)
  end
  replace_list(M.options, opts, { 'filetypes', 'image' })
  replace_list(M.options, opts, { 'filetypes', 'pdf' })
  replace_list(M.options, opts, { 'inline', 'filetypes' })
  return M.options
end

--- Lowercase extension of `path`, without the dot.
---@param path string
---@return string
function M.ext(path) return (path:match '%.([%w]+)$' or ''):lower() end

---@param path string
---@return "image"|"pdf"|nil
function M.kind(path)
  local ext = M.ext(path)
  if vim.tbl_contains(M.options.filetypes.pdf, ext) then return 'pdf' end
  if vim.tbl_contains(M.options.filetypes.image, ext) then return 'image' end
  return nil
end

return M
