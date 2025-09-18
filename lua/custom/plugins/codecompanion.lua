return {
  {
    'olimorris/codecompanion.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-treesitter/nvim-treesitter',
      'ravitemer/mcphub.nvim', -- Add MCPHub as dependency
    },
    config = function()
      local my_config = {
        -- Your existing CodeCompanion configuration
        -- adapters = {
        --   copilot = function()
        --     return require('codecompanion.adapters').extend('copilot', {
        --       schema = {
        --         model = {
        --           default = 'claude-3.5-sonnet',
        --         },
        --       },
        --     })
        --   end,
        -- },
        strategies = {
          -- chat = {
          --   adapter = 'openai', -- or your preferred adapter
          -- },
          -- inline = {
          --   adapter = 'openai',
          -- },
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
        opts = {
          chat_logging = {
            enabled = true, -- Enable chat logging
            log_dir = nil, -- Use default location
            auto_cleanup_days = 30, -- Auto-delete logs older than 30 days
          },
        },

        -- MCPHub extension configuration
        extensions = {
          mcphub = {
            callback = 'mcphub.extensions.codecompanion',
            opts = {
              show_result_in_chat = true, -- Show MCP tool results in chat
              make_vars = true, -- Convert MCP resources to #variables
              make_slash_commands = true, -- Add MCP prompts as /slash commands
            },
          },
        },

        -- Other CodeCompanion options...
        display = {
          action_palette = {
            width = 95,
            height = 10,
          },
          chat = {
            window = {
              layout = 'vertical', -- "vertical", "horizontal", "buffer"
            },
          },
        },
      }
      require('codecompanion').setup(my_config)
      require('codecompanion').config = my_config
    end,
  },
}
