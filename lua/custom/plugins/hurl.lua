return {
  {
    'jellydn/hurl.nvim',
    dependencies = { 'MunifTanjim/nui.nvim', 'nvim-lua/plenary.nvim' },
    ft = 'hurl',
    config = function()
      require('hurl').setup {
        debug = false,
        show_notification = false,
        auto_close = false,
        mode = 'split',
        env_file = { 'vars.env' },
        formatters = { json = { 'jq' } },
      }
      -- Collapse the "# Curl Command" section in hurl response split and jump to "# Body".
      -- The split buffer (filetype=markdown, unnamed) is populated via nvim_buf_set_lines
      -- *after* mount, so we hook TextChanged on it once per population cycle.
      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'markdown',
        callback = function(ev)
          local buf = ev.buf
          if vim.fn.bufname(buf) ~= '' then return end -- hurl split has no filename
          vim.api.nvim_create_autocmd('TextChanged', {
            buffer = buf,
            callback = function()
              vim.schedule(function()
                local first = (vim.api.nvim_buf_get_lines(buf, 0, 1, false))[1] or ''
                if not first:match '^# Request' then return end
                local win = vim.fn.bufwinid(buf)
                if win == -1 then return end
                vim.api.nvim_win_call(win, function()
                  local n = vim.api.nvim_buf_line_count(buf)
                  local curl_start, curl_end, body_start
                  for i = 1, n do
                    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ''
                    if l:match '^# Curl Command' then
                      curl_start = i
                    elseif curl_start and not curl_end and (l:match '^# ' or i == n) then
                      curl_end = i - 1
                    end
                    if l:match '^# Body' then body_start = i end
                  end
                  if curl_start and curl_end and curl_start < curl_end then
                    vim.wo.foldmethod = 'manual'
                    vim.cmd(('%d,%dfold'):format(curl_start, curl_end))
                  end
                  if body_start then
                    vim.api.nvim_win_set_cursor(win, { body_start, 0 })
                  end
                end)
              end)
            end,
          })
        end,
      })

      -- hurl reads the on-disk file, so save first to avoid entry-index mismatch
      -- when buffer has unsaved changes (e.g. freshly converted curl block)
      local function run(cmd)
        return function()
          if vim.bo.modified then
            vim.cmd 'write'
          end
          vim.cmd(cmd)
        end
      end
      vim.keymap.set('n', '<leader>hA', run 'HurlRunner', { desc = 'Hurl: Run all requests' })
      vim.keymap.set('n', '<leader>ha', run 'HurlRunnerAt', { desc = 'Hurl: Run request at cursor' })
      vim.keymap.set('n', '<leader>tv', run 'HurlVerbose', { desc = 'Hurl: Run request verbose' })
      vim.keymap.set('n', '<leader>tm', '<cmd>HurlToggleMode<CR>', { desc = 'Hurl: Toggle split/popup mode' })
      vim.keymap.set('v', '<leader>h', ':HurlRunner<CR>', { desc = 'Hurl: Run selection' })
      -- Refresh IAM token: pick env with vim.ui.select, write vars.env next to current file.
      -- Cached in ~/.cache/juniper/tokens/<env>.token; reuses until expiry.
      vim.keymap.set('n', '<leader>he', function()
        local envs = { 'c2dev3', 'c2dev2', 'sdpreprod' }
        vim.ui.select(envs, { prompt = 'Juniper env: ' }, function(env)
          if not env then
            return
          end
          local dir = vim.fn.expand '%:p:h'
          local vars_path = dir .. '/vars.env'
          local cmd = string.format('source ~/rcfiles/bin/juniper.sh && refreshHurlToken %s %s', env, vars_path)
          vim.fn.jobstart({ 'bash', '-c', cmd }, {
            on_exit = function(_, code)
              if code == 0 then
                vim.notify('Token ready for ' .. env .. ' → ' .. vars_path, vim.log.levels.INFO)
              else
                vim.notify('Token refresh failed for ' .. env, vim.log.levels.ERROR)
              end
            end,
          })
        end)
      end, { desc = 'Hurl: Refresh IAM token (pick env)' })
    end,
  },
}
