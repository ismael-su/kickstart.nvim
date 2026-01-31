return {
  -------------------------------------------------------------------
  -- Django / Jinja template support
  -------------------------------------------------------------------
  {
    'vim-scripts/django.vim',
    ft = { 'python', 'html' },
  },
  {
    'lepture/vim-jinja',
    ft = { 'html', 'jinja', 'jinja2' },
  },

  -------------------------------------------------------------------
  -- Treesitter: ensure Django-relevant languages are installed
  -------------------------------------------------------------------
  {
    'nvim-treesitter/nvim-treesitter',
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}

      local languages = {
        'python',
        'html',
        'css',
        'javascript',
        'json',
        'yaml',
        'sql',
        'bash',
      }

      for _, lang in ipairs(languages) do
        if not vim.tbl_contains(opts.ensure_installed, lang) then
          table.insert(opts.ensure_installed, lang)
        end
      end
    end,
  },

  -------------------------------------------------------------------
  -- Filetype detection for Django templates
  -------------------------------------------------------------------
  {
    'neovim/nvim-lspconfig',
    init = function()
      -- Treat Django templates as HTML (with Jinja highlighting)
      vim.filetype.add {
        pattern = {
          ['.*%.html'] = 'html',
        },
      }
    end,
  },
}
