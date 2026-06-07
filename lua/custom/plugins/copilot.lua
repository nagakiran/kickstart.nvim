return {
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    event = 'InsertEnter',
    config = function()
      require('copilot').setup {
        logger = {
          file = vim.fn.stdpath 'log' .. '/copilot-lua.log',
          file_log_level = vim.log.levels.OFF,
          print_log_level = vim.log.levels.WARN,
          trace_lsp = 'off',
          trace_lsp_progress = false,
          log_lsp_messages = false,
        },
        copilot_node_command = vim.fn.expand '$HOME' .. '/.nvm/versions/node/v22.21.1/bin/node',
        should_attach = function(bufnr, bufname)
          local filetype = vim.api.nvim_get_option_value('filetype', { buf = bufnr })

          -- Allow codecompanion chat buffers specifically
          if filetype == 'codecompanion' or filetype == 'ledger' then
            return true
          end

          if not vim.api.nvim_get_option_value('buflisted', { buf = bufnr }) then
            return false
          end

          local buftype = vim.api.nvim_get_option_value('buftype', { buf = bufnr })
          if buftype ~= '' then
            return false
          end

          return true
        end,
        suggestion = {
          enabled = true,
          auto_trigger = true,
          debounce = 75,
          keymap = {
            accept = '<M-l>',
            accept_word = '<M-w>',
            accept_line = '<M-e>',
            dismiss = '<C-]>',
          },
        },
        panel = {
          enabled = false,
        },
      }
    end,
  },
  {
    'zbirenbaum/copilot-cmp',
    enabled = false,
    after = { 'copilot.lua' },
    config = function()
      require('copilot_cmp').setup()
    end,
  },
  {
    'supermaven-inc/supermaven-nvim',
    enabled = false,
    config = function()
      require('supermaven-nvim').setup {
        keymaps = {
          accept_suggestion = '<m-tab>',
          clear_suggestion = '<m-k>',
          accept_word = '<m-j>',
        },
        ignore_filetypes = { cpp = true },
        disable_inline_completion = false,
      }
    end,
  },
}
