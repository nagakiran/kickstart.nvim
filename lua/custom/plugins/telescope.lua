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
      local previewers = require 'telescope.previewers'
      local putils = require 'telescope.previewers.utils'

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
          git_bcommits_range = {
            -- Same date/author format as git_bcommits. Must include --no-patch and END with
            -- `-L` so Telescope can append the `<from>,<to>:<file>` line-range argument.
            git_command = { 'git', 'log', '--pretty=%h %ad %an %s', '--abbrev-commit', '--date=short', '--no-patch', '-L' },
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
      -- Build a `git show`-style buffer previewer for the bcommits pickers. Runs git inside
      -- the file's own directory (-C <dir>) so it is robust to cwd/repo-root mismatch
      -- (vim-rooter, multiple buffers, etc.).
      --   title  preview window title
      --   args   function(rev, base) -> git args appended after `git -C <dir> --no-pager`
      --   ft     filetype used for syntax highlighting
      local function commit_previewer(title, args, ft)
        return previewers.new_buffer_previewer {
          title = title,
          get_buffer_by_name = function(_, entry)
            return entry.value
          end,
          define_preview = function(self, entry)
            local file = entry.current_file
            local dir = vim.fn.fnamemodify(file, ':p:h')
            local base = vim.fn.fnamemodify(file, ':t')
            local cmd = vim.list_extend({ 'git', '-C', dir, '--no-pager' }, args(entry.value, base))
            putils.job_maker(cmd, self.state.bufnr, {
              value = entry.value,
              bufname = self.state.bufname,
              cwd = dir,
              callback = function(bufnr)
                if vim.api.nvim_buf_is_valid(bufnr) then
                  putils.highlighter(bufnr, ft)
                end
              end,
            })
          end,
        }
      end

      -- Default bcommits preview: commit message + `--stat` file list (all files in the
      -- commit) + this file's diff. Runs git in the file's own dir for cwd-robustness.
      -- A single `git` invocation can't produce both the all-file stat and the focused
      -- diff, so this runs two commands and concatenates them (unlike commit_previewer).
      local function commit_stat_diff_previewer()
        return previewers.new_buffer_previewer {
          title = 'Stat + File Diff',
          get_buffer_by_name = function(_, entry)
            return entry.value
          end,
          define_preview = function(self, entry)
            local file = entry.current_file
            local dir = vim.fn.fnamemodify(file, ':p:h')
            local base = vim.fn.fnamemodify(file, ':t')
            local rev = entry.value
            -- `git show --stat` => message header + changed-files summary (all files)
            local stat = vim.fn.systemlist { 'git', '-C', dir, '--no-pager', 'show', '--stat', rev }
            -- `--format=` suppresses the message so we don't repeat the header
            local diff = vim.fn.systemlist { 'git', '-C', dir, '--no-pager', 'show', '--format=', rev, '--', base }
            local lines = vim.list_extend(stat, { '' })
            vim.list_extend(lines, diff)
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            putils.highlighter(self.state.bufnr, 'git')
          end,
        }
      end

      -- Previewer list for the bcommits pickers. Cycle with <C-Space>/<M-Space>.
      -- Default = commit message + all-file stat + this file's diff; then message-only,
      -- then diff-only.
      local function bcommits_previewers()
        return {
          commit_stat_diff_previewer(),
          commit_previewer('Commit Message', function(rev)
            return { 'log', '-n', '1', rev }
          end, 'git'),
          commit_previewer('File Diff to Parent', function(rev, base)
            return { 'show', '--format=', rev, '--', base } -- --format= suppresses the message header
          end, 'diff'),
        }
      end

      -- Shared picker mappings for the buffer-commit pickers (git_bcommits and
      -- git_bcommits_range). Both use the same entry maker, so `selection.value` (sha)
      -- and `selection.current_file` are available in either picker.
      -- The preview shows the full commit message (author/date/subject/body) followed by
      -- this file's diff; cycle the preview with <C-Space>/<M-Space>.
      -- Keybindings inside the picker:
      --   <CR>           → send all listed commits to the quickfix list
      --   <C-t>          → open the file snapshot at the selected commit in a new tab
      --   <C-d>          → open the full commit diff (all files) in a scratch buffer/new tab
      --   <C-v>          → side-by-side (vertical) diff of the commit vs its parent
      --   <C-x>          → stacked (horizontal) diff of the commit vs its parent
      --   <C-Space>      → cycle preview: stat+diff → message → diff (→ back)
      --   <M-Space>      → cycle preview the other way
      local function bcommits_attach_mappings(prompt_bufnr, map)
        -- Cycle between the combined / message-only / diff-only previewers.
        map({ 'i', 'n' }, '<C-Space>', actions.cycle_previewers_next)
        map({ 'i', 'n' }, '<M-Space>', actions.cycle_previewers_prev)

        -- <C-d>: open the WHOLE commit's diff (all files) in a scratch buffer in a new tab.
        -- NOTE: this overrides telescope's default <C-d> (preview_scrolling_down) for these
        -- pickers; <C-u> (scroll up) and the other defaults remain.
        map({ 'i', 'n' }, '<C-d>', function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          local dir = vim.fn.fnamemodify(selection.current_file, ':p:h')
          local rev = selection.value
          local content = vim.fn.systemlist { 'git', '-C', dir, '--no-pager', 'show', rev }
          if vim.v.shell_error ~= 0 then
            vim.notify('Failed to fetch commit diff', vim.log.levels.ERROR)
            return
          end
          vim.cmd 'tabnew'
          local buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
          vim.bo[buf].buftype = 'nofile' -- not backed by a real file
          vim.bo[buf].bufhidden = 'wipe' -- clean up when the tab is closed
          vim.bo[buf].filetype = 'git' -- highlights message + multi-file diff
          vim.api.nvim_buf_set_name(buf, 'COMMIT:' .. rev:sub(1, 7))
        end)

        -- Return the lines of `file` at git revision `rev`, or nil on failure.
        -- `git show <rev>:<path>` resolves <path> relative to the REPO ROOT, so run git
        -- inside the file's own directory and use a './'-prefixed pathspec. This is robust
        -- to Neovim's cwd not matching the repo root (vim-rooter, multiple buffers, etc.).
        local function git_file_lines(rev, file)
          local dir = vim.fn.fnamemodify(file, ':p:h')
          local base = vim.fn.fnamemodify(file, ':t')
          local content = vim.fn.systemlist { 'git', '-C', dir, 'show', rev .. ':./' .. base }
          if vim.v.shell_error ~= 0 then
            return nil
          end
          return content
        end

        -- Helper: open a diff view between the selected commit and its parent.
        -- `split_cmd` controls how the OLD buffer is placed (vertical / horizontal).
        local function diff_commit(split_cmd)
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr) -- close telescope before opening new windows

          -- Create a scratch buffer populated with `git show <rev>:<file>` output.
          -- `prefix` is used in the buffer name to label it NEW or OLD.
          local function create_git_buf(rev, prefix)
            local content = git_file_lines(rev, selection.current_file) -- file contents at `rev`
            if not content then
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

          vim.cmd 'tabnew'
          local new_buf = vim.api.nvim_get_current_buf()

          -- Retrieve the file contents at the exact commit SHA
          local content = git_file_lines(selection.value, selection.current_file)

          if not content then
            vim.notify('Failed to fetch git content', vim.log.levels.ERROR)
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
      end

      -- Normal mode: all commits that touched the current buffer.
      vim.keymap.set('n', '<leader>sb', function()
        builtin.git_bcommits { attach_mappings = bcommits_attach_mappings, previewer = bcommits_previewers() }
      end, { desc = '[S]earch [B]uffer Git Commits' })

      -- Visual mode: only commits that touched the SELECTED line range (git log -L).
      -- A plain Lua callback keeps visual mode active during execution, so
      -- git_bcommits_range picks up the selection via mode()/line "v".
      vim.keymap.set('x', '<leader>sb', function()
        builtin.git_bcommits_range { attach_mappings = bcommits_attach_mappings, previewer = bcommits_previewers() }
      end, { desc = '[S]earch [B]uffer Git Commits (selected range)' })

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

      -- Grep within a sub-directory chosen via an fzf-lua picker, rooted at the git root
      -- (robust to cwd != repo root under vim-rooter). Falls back to cwd if not in a repo.
      vim.keymap.set('n', '<leader>sD', function()
        local out = vim.fn.systemlist { 'git', '-C', vim.fn.expand '%:p:h', 'rev-parse', '--show-toplevel' }
        local root = out[1]
        if vim.v.shell_error ~= 0 or not root or root == '' then
          root = vim.fn.getcwd()
        end
        require('fzf-lua').fzf_exec('fd --type d --hidden --exclude .git', {
          prompt = 'Grep dir> ',
          cwd = root,
          actions = {
            ['default'] = function(selected)
              if not selected or not selected[1] then
                return
              end
              builtin.live_grep { search_dirs = { root .. '/' .. selected[1] } }
            end,
          },
        })
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
