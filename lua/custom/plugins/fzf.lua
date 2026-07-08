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

    vim.keymap.set('i', '<C-x><C-f>', function()
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
    end, { desc = 'Fuzzy-find file and insert path at cursor' })
  end,
}
