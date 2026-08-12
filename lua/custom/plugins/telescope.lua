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
      local gitctx = require 'gitctx' -- repo/path/revision of the current buffer (handles fugitive blobs)

      -- `git log` argv shared by every commit picker below, so the commit line always reads
      -- '<sha> <date> <author> <subject>' (telescope's entry maker splits off the sha and
      -- shows the rest as the message). Returns a fresh table each call.
      --   root   run git there via -C (nil = let telescope run it in opts.cwd)
      --   extra  flags appended after the format, e.g. { '--no-patch', '-L' }
      local function git_log_cmd(root, extra)
        local cmd = root and { 'git', '-C', root } or { 'git' }
        vim.list_extend(cmd, { 'log', '--pretty=%h %ad %an %s', '--abbrev-commit', '--date=short' })
        return vim.list_extend(cmd, extra or {})
      end

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
            -- To show date also in bcommits. NOTE: <leader>sb passes its own git_command
            -- (built by the same git_log_cmd) to scope the log to the buffer's revision, so
            -- this default only applies to git_bcommits invoked from elsewhere.
            git_command = git_log_cmd(),
          },
          git_bcommits_range = {
            -- Same date/author format as git_bcommits. Must include --no-patch and END with
            -- `-L` so Telescope can append the `<from>,<to>:<file>` line-range argument.
            git_command = git_log_cmd(nil, { '--no-patch', '-L' }),
          },
          git_commits = {
            -- To show date/author name also in bcommits
            git_command = git_log_cmd(),
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
      -- Build a `git show`-style buffer previewer for the bcommits pickers. Runs git at the
      -- repo root resolved by gitctx (-C <root>) with a repo-relative pathspec, so it is
      -- robust to cwd/repo-root mismatch (vim-rooter, worktrees, multiple buffers) and to
      -- files whose directory doesn't exist in the current checkout.
      --   ctx    gitctx context of the buffer the picker was opened from
      --   title  preview window title
      --   args   function(rev, relpath) -> git args appended after `git -C <root> --no-pager`
      --   ft     filetype used for syntax highlighting
      local function commit_previewer(ctx, title, args, ft)
        return previewers.new_buffer_previewer {
          title = title,
          get_buffer_by_name = function(_, entry)
            return entry.value
          end,
          define_preview = function(self, entry)
            local cmd = vim.list_extend({ 'git', '-C', ctx.root, '--no-pager' }, args(entry.value, ctx.relpath))
            putils.job_maker(cmd, self.state.bufnr, {
              value = entry.value,
              bufname = self.state.bufname,
              cwd = ctx.root,
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
      -- commit) + this file's diff. A single `git` invocation can't produce both the
      -- all-file stat and the focused diff, so this runs two commands and concatenates
      -- them (unlike commit_previewer).
      local function commit_stat_diff_previewer(ctx)
        return previewers.new_buffer_previewer {
          title = 'Stat + File Diff',
          get_buffer_by_name = function(_, entry)
            return entry.value
          end,
          define_preview = function(self, entry)
            local rev = entry.value
            -- `git show --stat` => message header + changed-files summary (all files)
            local stat = vim.fn.systemlist { 'git', '-C', ctx.root, '--no-pager', 'show', '--stat', rev }
            -- `--format=` suppresses the message so we don't repeat the header
            local diff = vim.fn.systemlist { 'git', '-C', ctx.root, '--no-pager', 'show', '--format=', rev, '--', ctx.relpath }
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
      local function bcommits_previewers(ctx)
        return {
          commit_stat_diff_previewer(ctx),
          commit_previewer(ctx, 'Commit Message', function(rev)
            return { 'log', '-n', '1', rev }
          end, 'git'),
          commit_previewer(ctx, 'File Diff to Parent', function(rev, relpath)
            return { 'show', '--format=', rev, '--', relpath } -- --format= suppresses the message header
          end, 'diff'),
        }
      end

      -- Shared picker mappings for the buffer-commit pickers (git_bcommits and
      -- git_bcommits_range). Both use the same entry maker, so `selection.value` (the sha)
      -- is available in either picker; the file itself comes from `ctx` (gitctx).
      -- The preview shows the full commit message (author/date/subject/body) followed by
      -- this file's diff; cycle the preview with <C-Space>/<M-Space>.
      -- Every commit is opened as a fugitive blob (fugitive://<gitdir>//<sha>/<path>), so
      -- <leader>sb, :Git blame and :0Gclog all work again from the result — the history
      -- walk chains instead of dead-ending in a scratch buffer.
      -- Keybindings inside the picker:
      --   <CR>           → send all listed commits to the quickfix list
      --   <C-t>          → open the file snapshot at the selected commit in a new tab
      --   <C-d>          → open the full commit diff (all files) in a scratch buffer/new tab
      --   <C-v>          → side-by-side (vertical) diff of the commit vs its parent
      --   <C-x>          → stacked (horizontal) diff of the commit vs its parent
      --   <C-Space>      → cycle preview: stat+diff → message → diff (→ back)
      --   <M-Space>      → cycle preview the other way
      local function bcommits_attach_mappings(ctx)
        return function(prompt_bufnr, map)
          -- Cycle between the combined / message-only / diff-only previewers.
          map({ 'i', 'n' }, '<C-Space>', actions.cycle_previewers_next)
          map({ 'i', 'n' }, '<M-Space>', actions.cycle_previewers_prev)

          -- <C-d>: open the WHOLE commit's diff (all files) in a scratch buffer in a new tab.
          -- NOTE: this overrides telescope's default <C-d> (preview_scrolling_down) for these
          -- pickers; <C-u> (scroll up) and the other defaults remain.
          map({ 'i', 'n' }, '<C-d>', function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            local rev = selection.value
            local content = vim.fn.systemlist { 'git', '-C', ctx.root, '--no-pager', 'show', rev }
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

          -- Open this file at the selected commit in a new tab. Returns the sha, or nil if
          -- the blob doesn't exist there (commits before a rename that --follow walked past).
          local function open_commit_blob()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr) -- close telescope before opening new windows
            local rev = selection.value
            if not gitctx.object_exists(ctx.root, rev, ctx.relpath) then
              vim.notify(ctx.relpath .. ' does not exist at ' .. rev:sub(1, 7) .. ' (renamed?)', vim.log.levels.WARN)
              return nil
            end
            return gitctx.open_blob(ctx.gitdir, rev, ctx.relpath, 'tabedit') and rev or nil
          end

          -- Diff the selected commit against its parent. `split_cmd` is fugitive's
          -- vertical/horizontal diff command; the parent lands in the new (left/top) window.
          local function diff_commit(split_cmd)
            local rev = open_commit_blob()
            if not rev then
              return
            end
            local parent = rev .. '^'
            if not gitctx.object_exists(ctx.root, parent, ctx.relpath) then
              vim.notify('No parent revision of ' .. ctx.relpath .. ' at ' .. rev:sub(1, 7) .. ' (added here?)', vim.log.levels.INFO)
              return
            end
            local ok, err = pcall(vim.cmd, split_cmd .. ' ' .. vim.fn.fnameescape(parent .. ':' .. ctx.relpath))
            if not ok then
              vim.notify(split_cmd .. ' failed — ' .. tostring(err), vim.log.levels.WARN)
            end
          end

          -- 1. <C-t>: Open the file snapshot at the selected commit in a new tab (no diff)
          actions.select_tab:replace(open_commit_blob)

          -- 2. <C-v>: Diff the selected commit against its parent in a vertical split
          actions.select_vertical:replace(function()
            diff_commit 'Gvdiffsplit'
          end)

          -- 3. <C-x>: Diff the selected commit against its parent in a horizontal split
          actions.select_horizontal:replace(function()
            diff_commit 'Gdiffsplit'
          end)

          -- 4. <CR>: Send all commits shown in the picker to the quickfix list
          actions.select_default:replace(function()
            actions.send_to_qflist(prompt_bufnr) -- populate quickfix
            actions.open_qflist(prompt_bufnr) -- and jump to it
          end)

          return true -- signal that mappings were successfully attached
        end
      end

      -- Shared opts for both bcommits pickers. Everything is pinned to the gitctx context so
      -- the picker follows the buffer's *revision*, not the checked-out HEAD: on a fugitive
      -- blob (a branch file opened by <leader>dF/<leader>dL without checking the branch out)
      -- `ctx.rev` is that branch's commit, so the log — and the -L line range, which is
      -- numbered against the blob in front of you — is scoped to that branch.
      --   `base_cmd` is completed by telescope, which appends opts.current_file (normal mode,
      --   hence the trailing '--' to keep git from reading the path as a revision) or the
      --   '<first>,<last>:<relpath>' spec (visual mode, after -L).
      local function bcommits_opts(ctx, base_cmd)
        return {
          cwd = ctx.root,
          current_file = ctx.abspath,
          git_command = base_cmd,
          attach_mappings = bcommits_attach_mappings(ctx),
          previewer = bcommits_previewers(ctx),
        }
      end

      -- Resolve the current buffer's repo/path/revision, or notify and return nil.
      local function bcommits_ctx()
        local ctx = gitctx.for_buf(0)
        if not ctx then
          vim.notify('Current buffer is not a file inside a git repository', vim.log.levels.WARN)
          return nil
        end
        return ctx
      end

      -- Normal mode: all commits that touched the current buffer.
      vim.keymap.set('n', '<leader>sb', function()
        local ctx = bcommits_ctx()
        if ctx then
          builtin.git_bcommits(bcommits_opts(ctx, git_log_cmd(ctx.root, { ctx.rev or 'HEAD', '--' })))
        end
      end, { desc = '[S]earch [B]uffer Git Commits' })

      -- Visual mode: only commits that touched the SELECTED line range (git log -L).
      -- A plain Lua callback keeps visual mode active during execution, so
      -- git_bcommits_range picks up the selection via mode()/line "v".
      vim.keymap.set('x', '<leader>sb', function()
        local ctx = bcommits_ctx()
        if ctx then
          builtin.git_bcommits_range(bcommits_opts(ctx, git_log_cmd(ctx.root, { '--no-patch', ctx.rev or 'HEAD', '-L' })))
        end
      end, { desc = '[S]earch [B]uffer Git Commits (selected range)' })

      -- Resolve the git root for the current buffer, falling back to cwd if the buffer
      -- isn't inside a repo (e.g. an empty/scratch buffer). Shared by the git_commits
      -- filters below and mirrors the resolution already used by <leader>sD/<leader>sG.
      local function git_root_for_current_buffer()
        return gitctx.root_for_buf(0)
      end

      -- Build the git_commits `git_command` for the given filters. Base format is the shared
      -- git_log_cmd used by every commit picker; flags are appended only when set.
      local function build_git_commits_command(filters)
        local cmd = git_log_cmd()
        if filters.author then
          table.insert(cmd, '--author=' .. filters.author)
        end
        if filters.since then
          table.insert(cmd, '--since=' .. filters.since)
        end
        if filters.until_ then
          table.insert(cmd, '--until=' .. filters.until_)
        end
        if filters.reverse then
          table.insert(cmd, '--reverse')
        end
        if filters.no_merges then
          table.insert(cmd, '--no-merges')
        end
        if filters.extra then
          for _, token in ipairs(vim.split(filters.extra, '%s+', { trimempty = true })) do
            table.insert(cmd, token)
          end
        end
        if filters.dir then
          table.insert(cmd, '--')
          table.insert(cmd, filters.dir)
        end
        return cmd
      end

      -- Render active filters + a key hint into the prompt title so the mappings are discoverable.
      local function git_commits_title(filters)
        local parts = {}
        if filters.dir then
          table.insert(parts, 'dir=' .. filters.dir)
        end
        if filters.author then
          table.insert(parts, 'author=' .. filters.author)
        end
        if filters.since then
          table.insert(parts, 'since=' .. filters.since)
        end
        if filters.until_ then
          table.insert(parts, 'until=' .. filters.until_)
        end
        if filters.no_merges then
          table.insert(parts, 'no-merges')
        end
        if filters.extra then
          table.insert(parts, 'extra=' .. filters.extra)
        end
        table.insert(parts, filters.reverse and 'oldest first' or 'newest first')
        local hint = 'M-a author · M-s since · M-u until · M-d dir · M-m merges · M-x extra · M-o order · M-r reset'
        return string.format('Git Commits (%s)  [%s]', table.concat(parts, ', '), hint)
      end

      -- Compute a repo-root-relative pathspec for the current buffer's directory, used to
      -- default <leader>sc to "commits touching this directory" instead of the whole repo.
      -- Symlink-resolved (matches lua/custom/plugins/fzf.lua's vim.uv.fs_realpath usage) so
      -- macOS's /tmp <-> /private/tmp style symlinks don't break the prefix comparison.
      local function default_dir_filter(root)
        if vim.bo.buftype ~= '' then
          return nil
        end
        local buf_dir = vim.fn.expand '%:p:h'
        if buf_dir == '' then
          return nil
        end
        local resolved_root = vim.uv.fs_realpath(root) or root
        local resolved_dir = vim.uv.fs_realpath(buf_dir) or buf_dir
        if resolved_dir == resolved_root then
          return nil
        end
        if resolved_dir:sub(1, #resolved_root + 1) == resolved_root .. '/' then
          return resolved_dir:sub(#resolved_root + 2)
        end
        return nil
      end

      -- Open git_commits scoped to `filters`; <M-a/s/u/o/r> refine-in-place by closing and
      -- recursively reopening with updated filters (git_commits' finder is a one-shot job, so
      -- there is no live/dynamic refinement -- reopening is the only way to change the git command).
      local function open_git_commits(filters)
        filters = filters or {}
        local root = git_root_for_current_buffer()
        builtin.git_commits {
          cwd = root,
          git_command = build_git_commits_command(filters),
          prompt_title = git_commits_title(filters),
          attach_mappings = function(prompt_bufnr, map)
            map({ 'i', 'n' }, '<M-a>', function()
              actions.close(prompt_bufnr)
              local lines = vim.fn.systemlist { 'git', 'shortlog', '-sne', '--all' }
              local items = {}
              for _, line in ipairs(lines) do
                local count, who = line:match '^%s*(%d+)\t(.+)$'
                if who then
                  table.insert(items, { count = tonumber(count), who = who })
                end
              end
              vim.ui.select(items, {
                prompt = 'Filter commits by author',
                format_item = function(item)
                  return string.format('%-4d %s', item.count, item.who)
                end,
              }, function(choice)
                local new_filters = vim.tbl_extend('force', {}, filters)
                new_filters.author = choice and choice.who or new_filters.author
                open_git_commits(new_filters)
              end)
            end)

            map({ 'i', 'n' }, '<M-s>', function()
              actions.close(prompt_bufnr)
              vim.ui.input({ prompt = 'Since (e.g. 2024-01-01, "2 weeks ago"): ', default = filters.since or '' }, function(value)
                local new_filters = vim.tbl_extend('force', {}, filters)
                if value ~= nil then
                  new_filters.since = value ~= '' and value or nil
                end
                open_git_commits(new_filters)
              end)
            end)

            map({ 'i', 'n' }, '<M-u>', function()
              actions.close(prompt_bufnr)
              vim.ui.input({ prompt = 'Until (e.g. 2024-06-01, "yesterday"): ', default = filters.until_ or '' }, function(value)
                local new_filters = vim.tbl_extend('force', {}, filters)
                if value ~= nil then
                  new_filters.until_ = value ~= '' and value or nil
                end
                open_git_commits(new_filters)
              end)
            end)

            -- Generic escape hatch for any git log flag not covered by a dedicated mapping
            -- above (e.g. -Sfoo pickaxe count, -Gregex pickaxe regex, --grep=foo, --all-match).
            -- Stored as the raw typed string (not pre-split) so re-opening this prompt shows
            -- exactly what was last entered; tokenized into argv elements in build_git_commits_command.
            map({ 'i', 'n' }, '<M-x>', function()
              actions.close(prompt_bufnr)
              vim.ui.input({
                prompt = 'Extra git log flags (space-separated, e.g. -Sfoo, -Gregex, --grep=foo, --all-match): ',
                default = filters.extra or '',
              }, function(value)
                local new_filters = vim.tbl_extend('force', {}, filters)
                if value ~= nil then
                  new_filters.extra = value ~= '' and value or nil
                end
                open_git_commits(new_filters)
              end)
            end)

            map({ 'i', 'n' }, '<M-o>', function()
              actions.close(prompt_bufnr)
              local new_filters = vim.tbl_extend('force', {}, filters)
              new_filters.reverse = not filters.reverse
              open_git_commits(new_filters)
            end)

            map({ 'i', 'n' }, '<M-m>', function()
              actions.close(prompt_bufnr)
              local new_filters = vim.tbl_extend('force', {}, filters)
              new_filters.no_merges = not filters.no_merges
              open_git_commits(new_filters)
            end)

            -- Pick a directory (fd + fzf-lua, mirrors <leader>sD) to scope commits to. Doesn't
            -- close the telescope prompt until a selection is made, so cancelling fzf (<Esc>)
            -- leaves the current picker/filters untouched instead of dropping out entirely.
            map({ 'i', 'n' }, '<M-d>', function()
              require('fzf-lua').fzf_exec('{ printf ".\\n"; fd --type d --hidden --exclude .git; }', {
                prompt = 'Filter commits by directory> ',
                cwd = root,
                actions = {
                  ['default'] = function(selected)
                    if not selected or not selected[1] then
                      return
                    end
                    actions.close(prompt_bufnr)
                    local new_filters = vim.tbl_extend('force', {}, filters)
                    if selected[1] == '.' then
                      new_filters.dir = nil
                    else
                      new_filters.dir = selected[1]
                    end
                    open_git_commits(new_filters)
                  end,
                },
              })
            end)

            map({ 'i', 'n' }, '<M-r>', function()
              actions.close(prompt_bufnr)
              open_git_commits {}
            end)

            return true
          end,
        }
      end

      vim.keymap.set('n', '<leader>sc', function()
        local root = git_root_for_current_buffer()
        open_git_commits { dir = default_dir_filter(root) }
      end, { desc = 'Git [C]ommits (current dir)' })
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
