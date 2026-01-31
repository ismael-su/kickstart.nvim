return {
  {
    'AckslD/swenv.nvim',
    config = function()
      local swenv = require 'swenv.api'

      -- Detect docker-compose / compose files
      local function is_docker_project(root)
        local compose = vim.fs.find({ 'docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml' }, { upward = true, path = root })
        return #compose > 0
      end

      local function auto_set_dotvenv()
        local cwd = vim.fn.getcwd()

        -- 🐳 If docker project → DO NOT activate host venv
        if is_docker_project(cwd) then
          return
        end

        -- 🔍 Look for .venv directory upward
        local venv = vim.fs.find('.venv', {
          upward = true,
          type = 'directory',
          path = cwd,
        })[1]

        if not venv then
          return
        end

        local venv_path = vim.fs.dirname(venv) .. '/.venv'

        -- 🧠 Avoid re-setting the same venv repeatedly
        if vim.env.VIRTUAL_ENV == venv_path then
          return
        end

        -- ✅ Activate venv + restart LSP
        swenv.set_venv(venv_path)
        vim.cmd 'LspRestart'
      end

      -- Auto-run when entering a project or changing directory
      vim.api.nvim_create_autocmd({ 'VimEnter', 'DirChanged' }, {
        callback = auto_set_dotvenv,
      })

      -- Optional manual picker
      vim.keymap.set('n', '<leader>ve', function()
        require('swenv.api').pick_venv()
      end, { desc = '[V]env [E]nvironment pick' })
    end,
  },
}
