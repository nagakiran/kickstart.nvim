return {
  'ibhagwan/fzf-lua',
  -- optional for icon support
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  config = function()
    -- calling `setup` is optional for customization
    -- https://github.com/ibhagwan/fzf-lua/blob/main/OPTIONS.md
    require('fzf-lua').setup {
      -- other configuration options
      git = {
        icons = {
          -- [Fzf-lua] 'git status' took 0.64 seconds, consider using `git_icons=false` in this repository or use `silent=true` to supress this message.
          git_icons = false, -- Disable git icons
        },
        status = {
          silent = true, -- Suppress the message
        },
      },
    }
    vim.keymap.set('n', '<leader>lf', '<cmd>FzfLua files<CR>', { desc = 'FzfLua files', nowait = true })
    vim.keymap.set('n', '<leader>ll', '<cmd>FzfLua blines<CR>', { desc = 'FzfLua blines', nowait = true })
    vim.keymap.set('n', '<leader>lL', '<cmd>FzfLua lines<CR>', { desc = 'FzfLua lines', nowait = true })
    vim.keymap.set('n', '<leader>lb', '<cmd>FzfLua buffers<CR>', { desc = 'FzfLua buffers', nowait = true })
    vim.keymap.set('n', '<leader>lg', '<cmd>FzfLua git_files<CR>', { desc = 'FzfLua git_files', nowait = true })
    vim.keymap.set('n', '<leader>ls', '<cmd>FzfLua treesitter<CR>', { desc = 'FZF [L]ist [S]ymbols (treesitter)', nowait = true })

    -- Filetypes where inserted paths should be relative to the current file's
    -- directory (import-style), rather than relative to cwd/project root.
    local relative_to_file_filetypes = {
      javascript = true,
      javascriptreact = true,
      typescript = true,
      typescriptreact = true,
      python = true,
      lua = true,
      go = true,
    }

    -- vim.fs.relpath only handles the case where `target` is nested under
    -- `base` (returns nil otherwise), so it can't produce "../"-style paths
    -- for sibling directories, which is the common case for imports.
    local function relative_path(base, target)
      local base_parts = vim.split(vim.fs.normalize(base), '/', { trimempty = true })
      local target_parts = vim.split(vim.fs.normalize(target), '/', { trimempty = true })
      local i = 1
      while base_parts[i] ~= nil and base_parts[i] == target_parts[i] do
        i = i + 1
      end
      local parts = {}
      for _ = i, #base_parts do
        table.insert(parts, '..')
      end
      for j = i, #target_parts do
        table.insert(parts, target_parts[j])
      end
      return table.concat(parts, '/')
    end

    -- Resolve through realpath (falling back to plain fnamemodify if the
    -- path doesn't exist yet, e.g. an unsaved buffer) so `base` and `abs`
    -- are always diffed on the same footing, even if either side sits
    -- behind a symlink.
    local function to_abs(path)
      return vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p')
    end

    -- Precomputed once: raw byte constants for the two control keys involved.
    local CTRL_X = vim.api.nvim_replace_termcodes('<C-x>', true, false, true) -- 0x18
    local CTRL_F = vim.api.nvim_replace_termcodes('<C-f>', true, false, true) -- 0x06

    vim.keymap.set('i', '<C-x>', function()
      -- Peek the very next raw keystroke synchronously -- no dependency on
      -- 'timeoutlen'. Mapping the literal 2-key sequence `<C-x><C-f>` would
      -- race Neovim's own timeoutlen: if the two keys don't land within that
      -- window, Neovim falls back to its native i_CTRL-X_* completion
      -- submode instead of firing our mapping. Intercepting `<C-x>` alone
      -- and resolving the next key ourselves is deterministic regardless of
      -- typing speed.
      local ok, key = pcall(vim.fn.getcharstr)
      if not ok then
        -- Interrupted (<C-c>) or read error: bail out cleanly, same as
        -- native Vim abandoning a pending <C-x> submode on interrupt.
        return
      end

      if key ~= CTRL_F then
        -- Not our chord: replay <C-x> + whatever was actually typed so
        -- native <C-x> submode dispatch (^P/^N/^O/^L, <Esc> to cancel,
        -- etc.) runs exactly as if we were never here.
        --   'n' -- noremap, only to avoid recursing back into THIS mapping
        --         (native <C-x> submodes are hardcoded, not keymap-table
        --         entries, so this doesn't hide them).
        --   'i' -- insert at front of typeahead, not append, so this
        --         replay is processed before any keys the user already
        --         typed ahead (fast typists), preserving input order.
        vim.api.nvim_feedkeys(CTRL_X .. key, 'ni', false)
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      vim.cmd 'stopinsert'
      -- Defer opening the picker to the next event-loop tick so the mode
      -- switch/redraw from `stopinsert` fully settles first; opening the
      -- terminal picker synchronously right after `stopinsert` races with
      -- that redraw and leaves the terminal cursor stuck at (1,1) instead
      -- of at the prompt, so the picker looks unfocused/not ready to type.
      vim.schedule(function()
        require('fzf-lua').files {
          actions = {
            ['default'] = function(selected)
              local file = require('fzf-lua.path').entry_to_file(selected[1], {}).path
              vim.schedule(function()
                local insert_path = file
                if relative_to_file_filetypes[vim.bo[bufnr].filetype] then
                  local abs = to_abs(file)
                  local base = vim.fn.fnamemodify(to_abs(vim.api.nvim_buf_get_name(bufnr)), ':h')
                  insert_path = relative_path(base, abs)
                  if not insert_path:match '^%.' then
                    insert_path = './' .. insert_path
                  end
                end
                vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { insert_path })
                vim.api.nvim_win_set_cursor(0, { row, col + #insert_path })
                vim.cmd 'startinsert'
              end)
            end,
          },
        }
      end)
    end, { desc = 'Fuzzy-find file and insert path at cursor (or native <C-x>... completion)' })
  end,
}
