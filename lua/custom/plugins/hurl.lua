return {
  {
    'jellydn/hurl.nvim',
    dependencies = { 'MunifTanjim/nui.nvim', 'nvim-lua/plenary.nvim' },
    ft = 'hurl',
    -- the collections picker and env switch work from any buffer, so they load the plugin too (lua/hurlc)
    keys = {
      {
        '<leader>hc',
        function()
          require('hurlc').pick()
        end,
        desc = 'Hurl: request collections',
      },
      {
        '<leader>he',
        function()
          require('hurlc').switch_env()
        end,
        desc = 'Hurl: switch environment (refresh IAM token)',
      },
    },
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
          if vim.fn.bufname(buf) ~= '' then
            return
          end -- hurl split has no filename
          vim.api.nvim_create_autocmd('TextChanged', {
            buffer = buf,
            callback = function()
              vim.schedule(function()
                local first = (vim.api.nvim_buf_get_lines(buf, 0, 1, false))[1] or ''
                if not first:match '^# Request' then
                  return
                end
                local win = vim.fn.bufwinid(buf)
                if win == -1 then
                  return
                end
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
                    if l:match '^# Body' then
                      body_start = i
                    end
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
      -- run_cursor saves first like `run`, and records the response in hurlc's history
      vim.keymap.set('n', '<leader>ha', function()
        require('hurlc').run_cursor()
      end, { desc = 'Hurl: Run request at cursor' })
      vim.keymap.set('n', '<leader>hH', function()
        require('hurlc').history()
      end, { desc = 'Hurl: response history of request at cursor' })
      vim.keymap.set('v', '<leader>h', ':HurlRunner<CR>', { desc = 'Hurl: Run selection' })
      -- environments are <root>/envs/*.env; <leader>he (in `keys` above) refreshes the IAM token and rewrites
      -- <root>/vars.env, which hurl.nvim finds from any collection subdirectory
      require('hurlc').setup()
    end,
  },
}
