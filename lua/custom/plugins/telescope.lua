return {
  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    branch = '0.1.x',
    dependencies = {
      'nvim-lua/popup.nvim',
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-media-files.nvim',
      'debugloop/telescope-undo.nvim',
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
      local undo_actions = require 'telescope-undo.actions'

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
            fname_width = 80,
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
          undo = {
            side_by_side = true,
            layout_strategy = 'vertical',
            layout_config = {
              preview_height = 0.8,
            },
            saved_only = true,
            mappings = {
              i = {},
            },
          },
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')
      pcall(require('telescope').load_extension, 'undo')
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
      vim.keymap.set('n', '<leader>si', builtin.changelist, { desc = 'Change List entries [I]nsert mode' })
      vim.keymap.set('n', '<leader>sb', function()
        builtin.git_bcommits {
          attach_mappings = function(prompt_bufnr, map)
            local function diff_commit(split_cmd)
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              local relative_path = vim.fn.fnamemodify(selection.current_file, ':.')

              local function create_git_buf(rev, prefix)
                local cmd = string.format('git show %s:%s', rev, relative_path)
                local content = vim.fn.systemlist(cmd)
                if vim.v.shell_error ~= 0 then
                  return nil
                end
                local bufnr = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
                vim.bo[bufnr].filetype = vim.filetype.match { filename = selection.current_file } or ''
                vim.bo[bufnr].buftype = 'nofile'
                vim.bo[bufnr].bufhidden = 'wipe'
                vim.api.nvim_buf_set_name(bufnr, prefix .. ':' .. selection.value:sub(1, 7) .. ':' .. vim.fn.fnamemodify(selection.current_file, ':t'))
                return bufnr
              end

              local buf_new = create_git_buf(selection.value, 'NEW')
              local buf_old = create_git_buf(selection.value .. '^', 'OLD')

              if not buf_new then
                vim.api.nvim_err_writeln 'Failed to fetch commit content'
                return
              end

              vim.cmd 'tabnew'
              vim.api.nvim_set_current_buf(buf_new)
              vim.cmd 'diffthis'
              if buf_old then
                vim.cmd(split_cmd .. ' ' .. buf_old)
                vim.cmd 'diffthis'
              end
            end

            -- 1. Open the file at the selected commit in a new tab
            actions.select_tab:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)

              local relative_path = vim.fn.fnamemodify(selection.current_file, ':.')

              vim.cmd 'tabnew'
              local new_buf = vim.api.nvim_get_current_buf()

              local cmd = string.format('git show %s:%s', selection.value, relative_path)
              local content = vim.fn.systemlist(cmd)

              if vim.v.shell_error ~= 0 then
                vim.api.nvim_err_writeln 'Failed to fetch git content'
                return
              end

              vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, content)

              vim.bo[new_buf].buftype = 'nofile'
              vim.bo[new_buf].bufhidden = 'wipe'
              vim.bo[new_buf].filetype = vim.filetype.match { filename = selection.current_file } or ''

              local short_sha = selection.value:sub(1, 7)
              local filename = vim.fn.fnamemodify(selection.current_file, ':t')
              vim.api.nvim_buf_set_name(new_buf, short_sha .. ':' .. filename)
            end)

            -- 2. Diff commit against its parent (Vertical)
            actions.select_vertical:replace(function()
              diff_commit 'leftabove vert sbuffer'
            end)

            -- 3. Diff commit against its parent (Horizontal)
            actions.select_horizontal:replace(function()
              diff_commit 'belowright sbuffer'
            end)

            -- 4. Populate all commits into quickfix on <CR>
            actions.select_default:replace(function()
              actions.send_to_qflist(prompt_bufnr)
              actions.open_qflist(prompt_bufnr)
            end)

            return true
          end,
        }
      end, { desc = '[S]earch [B]uffer Git Commits' })

      vim.keymap.set('n', '<leader>sc', builtin.git_commits, { desc = 'Git [C]ommits' })
      vim.keymap.set('n', '<leader>su', '<cmd>Telescope undo<cr>')

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
