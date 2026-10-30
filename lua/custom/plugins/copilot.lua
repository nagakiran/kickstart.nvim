-- copilot.lua needs Node 22+, and `node` on PATH can be an older nvm default (or absent when nvim is not
-- started from a login shell). Use the newest nvm install of 22+, else whatever `node` PATH gives.
-- scripts/install-deps.sh node installs one.
local function copilot_node()
  local best, best_version
  local nvm_dir = vim.env.NVM_DIR or (vim.env.HOME .. '/.nvm')
  for _, bin in ipairs(vim.fn.glob(nvm_dir .. '/versions/node/v*/bin/node', false, true)) do
    local version = vim.version.parse(bin:match '/node/(v[^/]+)/')
    if version and version.major >= 22 and (not best_version or vim.version.gt(version, best_version)) then
      best, best_version = bin, version
    end
  end
  return best or 'node'
end

return {
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    enabled = function()
      return not vim.g.disable_copilot_lua
    end,
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
        copilot_node_command = copilot_node(),
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

          -- Oversized notes files: auto_trigger would ship the whole document as context
          -- every 75ms of idle typing.
          if require('bigbuf').is_heavy(bufnr) then
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
    enabled = function()
      return not vim.g.disable_copilot_lua
    end,
    after = { 'copilot.lua' },
    config = function()
      require('copilot_cmp').setup()
    end,
  },
  {
    'supermaven-inc/supermaven-nvim',
    enabled = function()
      return vim.g.disable_copilot_lua == true
    end,
    config = function()
      require('supermaven-nvim').setup {
        keymaps = {
          accept_suggestion = '<m-tab>',
          clear_suggestion = '<m-k>',
          accept_word = '<m-w>',
        },
        ignore_filetypes = { cpp = true },
        disable_inline_completion = false,
      }
    end,
  },
}
