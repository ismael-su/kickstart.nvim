-- Toggle file tree
vim.keymap.set('n', '<leader>e', '<cmd>Neotree toggle<cr>', { desc = 'Explorer' })

-- Focus tree (jump to it if already open)
vim.keymap.set('n', '<leader>o', '<cmd>Neotree focus<cr>', { desc = 'Focus Explorer' })

vim.keymap.set('n', '<leader>g', '<cmd>Neotree git_status<cr>', { desc = 'Git Explorer' })
vim.keymap.set('n', '<leader>b', '<cmd>Neotree buffers<cr>', { desc = 'Buffer Explorer' })

vim.keymap.set('n', 'gd', require('telescope.builtin').lsp_definitions)
vim.keymap.set('n', 'gi', vim.lsp.buf.implementation)
vim.keymap.set('n', 'gr', require('telescope.builtin').lsp_references)
