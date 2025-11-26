return {
  {
    'olimorris/codecompanion.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-treesitter/nvim-treesitter',
      'ravitemer/mcphub.nvim', -- Add MCPHub as dependency
      'ravitemer/codecompanion-history.nvim',
    },
    build = function()
      local plugin_path = vim.fn.stdpath 'data' .. '/lazy/codecompanion.nvim'
      local patch_file = vim.fn.stdpath 'config' .. '/patches/codecompanion/skip_oauth.patch'
      vim.system({ 'patch', '-d', plugin_path, '-p1', '-i', patch_file }, { text = true }, function(obj)
        vim.schedule(function()
          if obj.code == 0 then
            vim.notify('Patched codecompanion.nvim successfully', vim.log.levels.INFO)
          end
        end)
      end)
    end,
    config = function()
      local my_config = {
        -- Your existing CodeCompanion configuration
        -- ACP adapters configuration for Gemini CLI
        -- adapters = {
        --   acp = {
        --     gemini_cli = function()
        --       return require('codecompanion.adapters').extend('gemini_cli', {
        --         defaults = {
        --           auth_method = 'oauth-personal', -- "oauth-personal"|"gemini-api-key"|"vertex-ai"
        --         },
        --         env = {
        --           -- GEMINI_API_KEY = 'cmd:op read op://personal/Gemini_API/credential --no-newline',
        --         },
        --       })
        --     end,
        --   },
        -- },
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
            opts = {
              system_prompt = function(ctx)
                -- Get the default system prompt from the config
                -- local default_config = require('codecompanion.config').default
                -- local default_prompt = default_config.strategies.chat.opts.system_prompt(args)

                -- Replace the line that disallows diff formatting with one that encourages it
                local default_prompt = ctx.default_system_prompt:gsub(
                  'Do not include diff formatting unless explicitly asked%.',
                  'When displaying diffs or patches for review (not using insert_edit_into_file tool), wrap them in ````diff code blocks. Do not use markers like "*** Begin Patch" and "*** End Patch".'
                )

                return default_prompt
              end,
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
          history = {
            enabled = false,
            opts = {
              default_buf_title = '[CodeCompanion] ', -- No special characters
              -- Keymap to open history from chat buffer (default: gh)
              keymap = 'gh',
              -- Keymap to save the current chat manually (when auto_save is disabled)
              save_chat_keymap = 'sc',
              -- Save all chats by default (disable to save only manually using 'sc')
              auto_save = true,
              -- Number of days after which chats are automatically deleted (0 to disable)
              expiration_days = 0,
              -- Picker interface (auto resolved to a valid picker)
              picker = 'telescope', --- ("telescope", "snacks", "fzf-lua", or "default")
              ---Optional filter function to control which chats are shown when browsing
              chat_filter = nil, -- function(chat_data) return boolean end
              -- Customize picker keymaps (optional)
              picker_keymaps = {
                rename = { n = 'r', i = '<M-r>' },
                delete = { n = 'd', i = '<M-d>' },
                duplicate = { n = '<C-y>', i = '<C-y>' },
              },
              ---Automatically generate titles for new chats
              auto_generate_title = true,
              title_generation_opts = {
                ---Adapter for generating titles (defaults to current chat adapter)
                -- adapter = nil, -- "copilot"
                adapter = 'copilot',
                ---Model for generating titles (defaults to current chat model)
                -- model = nil, -- "gpt-4o"
                model = 'gpt-4.1',
                ---Number of user prompts after which to refresh the title (0 to disable)
                refresh_every_n_prompts = 0, -- e.g., 3 to refresh after every 3rd user prompt
                ---Maximum number of times to refresh the title (default: 3)
                max_refreshes = 3,
                format_title = function(original_title)
                  -- this can be a custom function that applies some custom
                  -- formatting to the title.
                  return original_title
                end,
              },
              ---On exiting and entering neovim, loads the last chat on opening chat
              continue_last_chat = false,
              ---When chat is cleared with `gx` delete the chat from history
              delete_on_clearing_chat = false,
              ---Directory path to save the chats
              dir_to_save = vim.fn.stdpath 'data' .. '/codecompanion-history',
              ---Enable detailed logging for history extension
              enable_logging = false,

              -- Summary system
              summary = {
                -- Keymap to generate summary for current chat (default: "gcs")
                create_summary_keymap = 'gcs',
                -- Keymap to browse summaries (default: "gbs")
                browse_summaries_keymap = 'gbs',
                generation_opts = {
                  -- adapter = nil, -- defaults to current chat adapter
                  -- model = nil, -- defaults to current chat model
                  adapter = 'copilot',
                  model = 'gpt-4.1',
                  context_size = 90000, -- max tokens that the model supports
                  include_references = true, -- include slash command content
                  include_tool_outputs = true, -- include tool execution results
                  system_prompt = nil, -- custom system prompt (string or function)
                  format_summary = nil, -- custom function to format generated summary e.g to remove <think/> tags from summary
                },
              },
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
