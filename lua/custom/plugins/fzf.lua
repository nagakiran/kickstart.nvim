return {
  'ibhagwan/fzf-lua',
  -- optional for icon support
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  config = function()
    -- calling `setup` is optional for customization
    -- https://github.com/ibhagwan/fzf-lua/blob/main/OPTIONS.md
    require('fzf-lua').setup {}
    vim.keymap.set('n', '<leader>lf', '<cmd>FzfLua files<CR>', { desc = 'FzfLua files', nowait = true })
    vim.keymap.set('n', '<leader>ll', '<cmd>FzfLua blines<CR>', { desc = 'FzfLua blines', nowait = true })
    vim.keymap.set('n', '<leader>lL', '<cmd>FzfLua lines<CR>', { desc = 'FzfLua lines', nowait = true })
    vim.keymap.set('n', '<leader>lb', '<cmd>FzfLua buffers<CR>', { desc = 'FzfLua buffers', nowait = true })
    vim.keymap.set('n', '<leader>lg', '<cmd>FzfLua git_files<CR>', { desc = 'FzfLua git_files', nowait = true })
  end,
}
