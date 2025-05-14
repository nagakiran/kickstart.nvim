return {
  'olimorris/codecompanion.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-treesitter/nvim-treesitter',
    -- The following are optional:
    { 'MeanderingProgrammer/render-markdown.nvim', ft = { 'markdown', 'codecompanion' } },
  },
  opts = {
    strategies = {
      chat = {
        slash_commands = {
          ['file'] = {
            -- Location to the slash command in CodeCompanion
            callback = 'strategies.chat.slash_commands.file',
            description = 'Select a file using Telescope',
            opts = {
              provider = 'telescope', -- Other options include 'default', 'mini_pick', 'fzf_lua', snacks
              contains_code = true,
            },
          },
        },
      },
    },
  },
  config = true,
}
