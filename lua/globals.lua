vim.opt.tabstop = 2

-- Machine-local overrides (gitignored). See lua/local_config.lua.example.
vim.g.disable_copilot_lua = false
pcall(require, 'local_config')
