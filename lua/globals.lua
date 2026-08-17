vim.opt.tabstop = 2

-- Machine-local overrides (gitignored). See lua/local_config.lua.example.
vim.g.disable_copilot_lua = false

-- CodeCompanion's copilot adapter. Defaults are the base models, which every Copilot plan can
-- serve (the free SKU serves *only* these). Machines with a paid subscription can raise
-- cc_copilot_model in local_config.lua — see lua/local_config.lua.example.
vim.g.cc_copilot_model = 'gpt-4.1'
-- Titles and summaries. Keep this on a base model even on paid plans: those are 0 premium
-- requests, while Claude models bill 1x each, and chat titles aren't worth the quota.
vim.g.cc_copilot_utility_model = 'gpt-4.1'

pcall(require, 'local_config')
