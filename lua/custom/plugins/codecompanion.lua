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
          chat = {
            roles = {
              llm = function(adapter)
                local model = adapter.model
                -- Some adapters store model on .schema.model.default, some on .model, and value may be string or table
                if not model and adapter.schema and adapter.schema.model then
                  model = adapter.schema.model.default
                end
                -- If it's a function, call it to get the real value
                if type(model) == 'function' then
                  model = model(adapter)
                end
                -- If it's a table, attempt to extract an id or name field. Otherwise, fallback to string.
                if type(model) == 'table' then
                  model = model.id or model.name or model.label or vim.inspect(model)
                end
                -- Fallback: If model is not a string by now, skip appending it
                if type(model) == 'string' and model ~= '' then
                  return 'CodeCompanion (' .. adapter.formatted_name .. ' - ' .. model .. ')'
                else
                  return 'CodeCompanion (' .. adapter.formatted_name .. ')'
                end
              end,
              ---The header name for your messages
              ---@type string
              user = 'Me',
            },
          },

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
