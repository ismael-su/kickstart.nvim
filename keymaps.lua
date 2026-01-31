-- Toggle file tree
vim.keymap.set('n', '<leader>e', '<cmd>Neotree toggle<cr>', { desc = 'Explorer' })

-- Focus tree (jump to it if already open)
vim.keymap.set('n', '<leader>o', '<cmd>Neotree focus<cr>', { desc = 'Focus Explorer' })

vim.keymap.set('n', '<leader>g', '<cmd>Neotree git_status<cr>', { desc = 'Git Explorer' })
vim.keymap.set('n', '<leader>b', '<cmd>Neotree buffers<cr>', { desc = 'Buffer Explorer' })
