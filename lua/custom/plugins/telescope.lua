return {
  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/popup.nvim',
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-media-files.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',

        -- `build` is used to run some command when the plugin is installed/updated.
        -- This is only run then, not every time Neovim starts up.
        build = 'make',

        -- `cond` is a condition used to determine whether this plugin should be
        -- installed and loaded.
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      { 'nvim-telescope/telescope-ui-select.nvim' },

      -- Useful for getting pretty icons, but requires a Nerd Font.
      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
    },
    config = function()
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'

      -- [[ Configure Telescope ]]
      -- See `:help telescope` and `:help telescope.setup()`
      require('telescope').setup {
        defaults = {
          mappings = {
            i = {
              ['<C-a>'] = require('telescope.actions').toggle_all,
              ['<C-j>'] = require('telescope.actions').move_selection_next,
              ['<C-k>'] = require('telescope.actions').move_selection_previous,
              ['<C-f>'] = require('telescope.actions').results_scrolling_down,
              ['<C-b>'] = require('telescope.actions').results_scrolling_up,
            },
            n = {
              ['<C-a>'] = require('telescope.actions').toggle_all,
              ['<C-j>'] = require('telescope.actions').move_selection_next,
              ['<C-k>'] = require('telescope.actions').move_selection_previous,
              ['<C-f>'] = require('telescope.actions').results_scrolling_down,
              ['<C-b>'] = require('telescope.actions').results_scrolling_up,
            },
          },
        },
        pickers = {
          jumplist = {
            show_line = false,
          },
          lsp_references = {
            fname_width = 150,
            layout_strategy = 'vertical',
            layout_config = {
              width = 0.95,
              height = 0.85,
              preview_height = 0.6,
            },
            path_display = { 'truncate' },
          },
          git_bcommits = {
            -- To show date also in bcommits
            git_command = { 'git', 'log', '--pretty=%h %ad %an %s', '--abbrev-commit', '--date=short' },
          },
          git_commits = {
            -- To show date/author name also in bcommits
            git_command = { 'git', 'log', '--pretty=%h %ad %an %s', '--abbrev-commit', '--date=short' },
          },
        },
        extensions = {
          media_files = {
            filetypes = { 'png', 'webp', 'jpg', 'jpeg' },
            find_cmd = 'rg',
            preview_cmd = 'imgcat',
          },
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')
      pcall(require('telescope').load_extension, 'media_files')

      -- See `:help telescope.builtin`
      local builtin = require 'telescope.builtin'
      vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
      vim.keymap.set('n', '<leader>sl', builtin.git_files, { desc = '[S]earch Git [l]s-files' })
      vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      vim.keymap.set('n', '<leader>lm', builtin.marks, { desc = '[L]ist marks' })
      vim.keymap.set('n', '<leader>lt', builtin.help_tags, { desc = '[L]ist [t]ags' })
      vim.keymap.set('n', '<leader>lh', builtin.help_tags, { desc = '[L]ist [H]elp tags' })
      vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      vim.keymap.set('n', '<leader>sH', function()
        require('telescope.builtin').live_grep {
          additional_args = function(args)
            return { '--hidden' }
          end,
        }
      end, { desc = '[S]earch by [H]idden Grep' })
      vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
      vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
      vim.keymap.set('n', '<leader>sj', builtin.jumplist, { desc = '[J]ump List entries' })
      if builtin.changelist then
        vim.keymap.set('n', '<leader>si', builtin.changelist, { desc = 'Change List entries [I]nsert mode' })
      end
      -- <leader>sb: Browse git commits for the current buffer (git bcommits).
      -- Keybindings inside the picker:
      --   <CR>         → send all listed commits to the quickfix list
      --   <C-t>        → open the file snapshot at the selected commit in a new tab
      --   <C-v>        → side-by-side (vertical) diff of the commit vs its parent
      --   <C-x>        → stacked (horizontal) diff of the commit vs its parent
      vim.keymap.set('n', '<leader>sb', function()
        builtin.git_bcommits {
          attach_mappings = function(prompt_bufnr, map)
            -- Helper: open a diff view between the selected commit and its parent.
            -- `split_cmd` controls how the OLD buffer is placed (vertical / horizontal).
            local function diff_commit(split_cmd)
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr) -- close telescope before opening new windows
              local relative_path = vim.fn.fnamemodify(selection.current_file, ':.') -- path relative to cwd

              -- Create a scratch buffer populated with `git show <rev>:<file>` output.
              -- `prefix` is used in the buffer name to label it NEW or OLD.
              local function create_git_buf(rev, prefix)
                local cmd = string.format('git show %s:%s', rev, relative_path)
                local content = vim.fn.systemlist(cmd) -- run git and capture output lines
                if vim.v.shell_error ~= 0 then
                  return nil -- git command failed (e.g. file didn't exist at that rev)
                end
                local bufnr = vim.api.nvim_create_buf(false, true) -- unlisted, scratch buffer
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
                vim.bo[bufnr].filetype = vim.filetype.match { filename = selection.current_file } or '' -- preserve syntax highlighting
                vim.bo[bufnr].buftype = 'nofile' -- not backed by a real file
                vim.bo[bufnr].bufhidden = 'wipe' -- auto-delete when hidden
                -- Name format: NEW:<sha7>:<filename>  or  OLD:<sha7>:<filename>
                vim.api.nvim_buf_set_name(bufnr, prefix .. ':' .. selection.value:sub(1, 7) .. ':' .. vim.fn.fnamemodify(selection.current_file, ':t'))
                return bufnr
              end

              local buf_new = create_git_buf(selection.value, 'NEW') -- the selected commit
              local buf_old = create_git_buf(selection.value .. '^', 'OLD') -- its parent commit (^ suffix)

              if not buf_new then
                vim.api.nvim_err_writeln 'Failed to fetch commit content'
                return
              end

              vim.cmd 'tabnew' -- open a fresh tab for the diff
              vim.api.nvim_set_current_buf(buf_new) -- load NEW side into the tab
              vim.cmd 'diffthis' -- mark NEW as a diff window
              if buf_old then
                vim.cmd(split_cmd .. ' ' .. buf_old) -- open OLD in a split next to NEW
                vim.cmd 'diffthis' -- mark OLD as a diff window
              end
            end

            -- 1. <C-t>: Open the file snapshot at the selected commit in a new tab (no diff)
            actions.select_tab:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)

              local relative_path = vim.fn.fnamemodify(selection.current_file, ':.')

              vim.cmd 'tabnew'
              local new_buf = vim.api.nvim_get_current_buf()

              -- Retrieve the file contents at the exact commit SHA
              local cmd = string.format('git show %s:%s', selection.value, relative_path)
              local content = vim.fn.systemlist(cmd)

              if vim.v.shell_error ~= 0 then
                vim.api.nvim_err_writeln 'Failed to fetch git content'
                return
              end

              vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, content)

              vim.bo[new_buf].buftype = 'nofile' -- read-only scratch buffer
              vim.bo[new_buf].bufhidden = 'wipe' -- clean up when the tab is closed
              vim.bo[new_buf].filetype = vim.filetype.match { filename = selection.current_file } or ''

              -- Name the buffer <sha7>:<filename> for easy identification in the tabline
              local short_sha = selection.value:sub(1, 7)
              local filename = vim.fn.fnamemodify(selection.current_file, ':t')
              vim.api.nvim_buf_set_name(new_buf, short_sha .. ':' .. filename)
            end)

            -- 2. <C-v>: Diff the selected commit against its parent in a vertical split
            actions.select_vertical:replace(function()
              diff_commit 'leftabove vert sbuffer'
            end)

            -- 3. <C-x>: Diff the selected commit against its parent in a horizontal split
            actions.select_horizontal:replace(function()
              diff_commit 'belowright sbuffer'
            end)

            -- 4. <CR>: Send all commits shown in the picker to the quickfix list
            actions.select_default:replace(function()
              actions.send_to_qflist(prompt_bufnr) -- populate quickfix
              actions.open_qflist(prompt_bufnr) -- and jump to it
            end)

            return true -- signal that mappings were successfully attached
          end,
        }
      end, { desc = '[S]earch [B]uffer Git Commits' })

      vim.keymap.set('n', '<leader>sc', builtin.git_commits, { desc = 'Git [C]ommits' })
      vim.keymap.set('n', '<leader>su', '<cmd>Atone<cr>', { desc = '[S]earch [U]ndo tree (atone)' })

      -- To search from git root directory instead of current directory
      vim.keymap.set('n', '<leader>sG', function()
        local git_dir = vim.fn.system(string.format('git -C %s rev-parse --show-toplevel', vim.fn.expand '%:p:h'))
        git_dir = string.gsub(git_dir, '\n', '')
        local opts = {
          cwd = git_dir,
        }
        builtin.live_grep(opts)
      end, { desc = '[S]earch by [G]rep from git root' })

      -- Grep within a specific subdirectory (prompts for path with tab-completion)
      vim.keymap.set('n', '<leader>sD', function()
        local dir = vim.fn.input('Search dir: ', '', 'dir')
        if dir == '' then
          return
        end
        builtin.live_grep { search_dirs = { dir } }
      end, { desc = '[S]earch in sub[D]irectory' })

      vim.keymap.set('n', '<leader>/', function()
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = '[/] Fuzzily search in current buffer' })

      vim.keymap.set('n', '<leader>s/', function()
        builtin.live_grep {
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        }
      end, { desc = '[S]earch [/] in Open Files' })

      vim.keymap.set('n', '<leader>s?', function()
        builtin.live_grep(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
          search_dirs = { vim.fn.expand '%:p' },
          prompt_title = 'Literal Search in Current Buffer',
          path_display = { 'hidden' },
        })
      end, { desc = '[?] Literal search in current buffer' })

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>sn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[S]earch [N]eovim files' })
    end,
  },
}
