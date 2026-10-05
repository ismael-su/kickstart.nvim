-- Registers commands and autocmds. This has to run before any file is read,
-- because `BufReadCmd` is what stops Neovim loading a PNG as text.
if vim.g.loaded_inlineview then return end
vim.g.loaded_inlineview = true

require('inlineview').bootstrap()
