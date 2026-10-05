-- inlineview.nvim -- view images and PDFs inline, without leaving Neovim.
--
-- The plugin lives in this repo under `local/inlineview.nvim/`, so there is
-- nothing to fetch and it stays versioned with the rest of the config.
--
--   :InlineView [path]   open an image or PDF in a floating window
--   :InlineViewInline    toggle in-buffer rendering of markdown image links
--   :InlineViewInfo      show what the plugin detected about this terminal
--   :checkhealth inlineview
--
-- Inside the viewer: n/p page, +/- zoom, hjkl pan, w/f fit, q close, ? help.

return {
  {
    name = 'inlineview.nvim',
    dir = vim.fn.stdpath 'config' .. '/local/inlineview.nvim',

    -- Must not be lazy-loaded: `BufReadCmd` has to be registered before the
    -- first file is read, otherwise `nvim diagram.png` loads binary as text.
    lazy = false,

    opts = {
      -- Detection handles iTerm2 (incl. over SSH via LC_TERMINAL), Kitty,
      -- Ghostty and WezTerm, falling back to chafa half-blocks.
      backend = 'auto',
      auto_open = true,
      fit = 'contain',

      inline = {
        enabled = true,
        filetypes = { 'markdown', 'quarto', 'rmd' },
        max_rows = 20,
      },
    },

    keys = {
      { '<leader>iv', '<cmd>InlineView<cr>', desc = '[I]mage [V]iew this file' },
      { '<leader>ii', '<cmd>InlineViewInline<cr>', desc = '[I]mage [I]nline toggle' },
      { '<leader>ir', '<cmd>InlineViewRefresh<cr>', desc = '[I]mage [R]efresh/repaint' },
    },
  },
}
