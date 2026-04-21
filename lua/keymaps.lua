-- Toggle file tree
vim.keymap.set('n', '<leader>e', '<cmd>Neotree toggle<cr>', { desc = 'Explorer' })

-- Focus tree (jump to it if already open)
vim.keymap.set('n', '<leader>o', '<cmd>Neotree focus<cr>', { desc = 'Focus Explorer' })

vim.keymap.set('n', '<leader>g', '<cmd>Neotree git_status<cr>', { desc = 'Git Explorer' })
vim.keymap.set('n', '<leader>b', '<cmd>Neotree buffers<cr>', { desc = 'Buffer Explorer' })

vim.keymap.set('n', 'gd', require('telescope.builtin').lsp_definitions)
vim.keymap.set('n', 'gi', vim.lsp.buf.implementation)
vim.keymap.set('n', 'gr', require('telescope.builtin').lsp_references)

-- Claude code
vim.keymap.set('n', '<leader>cc', '<cmd>ClaudeCode<CR>', { desc = 'Toggle Claude Code' })
vim.keymap.set('n', '<leader>cr', '<cmd>ClaudeCodeResume<CR>', { desc = 'Resume Claude Code' })

-- Android
vim.keymap.set('n', '<leader>ab', '<cmd>term ./gradlew assembleDebug<CR>', { desc = '[A]ndroid [B]uild' })
vim.keymap.set('n', '<leader>ar', '<cmd>term ./gradlew installDebug && adb shell am start -n com.memoi.vfrfr/.MainActivity<CR>', { desc = '[A]ndroid [R]un' })
vim.keymap.set('n', '<leader>aa', '<cmd>!adb start-server<CR>', { desc = '[A]ndroid [A]DB start' })
vim.keymap.set('n', '<leader>ae', '<cmd>!$ANDROID_HOME/emulator/emulator -avd Pixel_4 &<CR>', { desc = '[A]ndroid [E]mulator' })
