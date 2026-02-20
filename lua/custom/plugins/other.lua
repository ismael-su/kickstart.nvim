return {
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'yaml',
    callback = function()
      vim.opt.shiftwidth = 2 -- indentation size
      vim.opt.tabstop = 2 -- how a <Tab> displays
      vim.opt.softtabstop = 2 -- tab "feels like" 2 spaces
      vim.opt.expandtab = true -- convert tab → spaces
    end,
  }),
}
