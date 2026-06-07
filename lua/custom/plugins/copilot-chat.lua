return {
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    dependencies = {
      { 'zbirenbaum/copilot.lua' },
      { 'nvim-lua/plenary.nvim', branch = 'master' },
    },
    build = 'make tiktoken',
    opts = {
      mappings = {
        complete = {
          detail = 'Use @<Tab> or /<Tab> for options.',
          insert = '<S-Tab>',
        },
      },
      contexts = {
        file = {
          input = function(callback)
            local fzf = require 'fzf-lua'
            local fzf_path = require 'fzf-lua.path'
            fzf.files {
              complete = function(selected, opts)
                local file = fzf_path.entry_to_file(selected[1], opts, opts._uri)
                if file.path == 'none' then
                  return
                end
                vim.defer_fn(function()
                  callback(file.path)
                end, 100)
              end,
            }
          end,
        },
      },
    },
    keys = {
      { '<leader>av', '<cmd>CopilotChatToggle<cr>', desc = 'Co[p]ilotChatToggle' },
      { '<leader>pr', '<cmd>CopilotChatReset<cr>', desc = 'Co[p]ilotChatReset' },
    },
  },
}
