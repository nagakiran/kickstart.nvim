return {
  {
    'sindrets/diffview.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory' },
    keys = {
      { '<leader>dF', desc = 'Juniper: open diff file in 2-way vimdiff' },
      { '<leader>dL', desc = 'Juniper: open feature-branch file in new tab' },
      { '<leader>dJ', desc = 'Juniper: DiffviewOpen for stored branches' },
      { '<leader>dq', desc = 'Diffview: close panel' },
    },
    config = function()
      -- The file panel's tree indent is hardcoded in diffview's render module (2 columns per
      -- level for folders, 2 more for files), which hides long filenames in a narrow panel.
      -- Load that module from the plugin's own source with the indent cut to 1 column per
      -- level, so a file sits 1 column right of its folder's name. The module is required
      -- lazily on each render, so a preload set here wins. If upstream changes the code and
      -- the patterns stop matching, the stock module loads unchanged.
      package.preload['diffview.scene.views.diff.render'] = function(modname)
        local path = vim.api.nvim_get_runtime_file('lua/diffview/scene/views/diff/render.lua', false)[1]
        local src = path and table.concat(vim.fn.readfile(path), '\n')
        if src then
          local n1, n2
          src, n1 = src:gsub('depth %* 2 %+ 2', 'depth + 1')
          src, n2 = src:gsub('depth %* 2%)', 'depth)')
          if n1 == 1 and n2 == 1 then
            local chunk = load(src, '@' .. path)
            if chunk then
              return chunk(modname)
            end
          end
        end
        assert(path, 'diffview render module not found')
        return dofile(path)
      end

      -- gu: show the current diffview entry as a unified `git diff` in a new tab (`q` closes
      -- it). Diffview has no single-pane diff layout. The two revisions come from the entry
      -- itself, so this works in both DiffviewOpen and DiffviewFileHistory, and against the
      -- working tree or the index when the view compares those.
      local function unified_diff()
        local view = require('diffview.lib').get_current_view()
        local file = view and view:infer_cur_file()
        if not file or not file.revs or not file.revs.a or not file.revs.b then
          vim.notify('No diffview file entry here', vim.log.levels.WARN)
          return
        end
        local RevType = require('diffview.vcs.rev').RevType
        local a, b = file.revs.a, file.revs.b
        local args = { 'git', '-C', file.adapter.ctx.toplevel, 'diff', '--no-color', '-M' }
        if b.type == RevType.STAGE then
          table.insert(args, '--cached')
        end
        if a.type == RevType.COMMIT then
          table.insert(args, a.commit)
        end
        if b.type == RevType.COMMIT then
          table.insert(args, b.commit)
        end
        table.insert(args, '--')
        if file.oldpath and file.oldpath ~= file.path then
          table.insert(args, file.oldpath)
        end
        table.insert(args, file.path)

        local res = vim.system(args, { text = true }):wait()
        if res.code ~= 0 then
          vim.notify('git diff failed: ' .. (res.stderr or ''), vim.log.levels.WARN)
          return
        end
        vim.cmd 'tabnew'
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(res.stdout, '\n', { trimempty = true }))
        vim.bo[buf].buftype = 'nofile'
        vim.bo[buf].bufhidden = 'wipe'
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = 'diff'
        pcall(vim.api.nvim_buf_set_name, buf, 'unified://' .. file.path)
        vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf, desc = 'Close unified diff' })
      end
      local gu = { 'n', 'gu', unified_diff, { desc = 'Unified diff of this file in a new tab' } }

      require('diffview').setup {
        use_icons = false,
        file_panel = { win_config = { width = 40 } },
        keymaps = { view = { gu }, file_panel = { gu }, file_history_panel = { gu } },
      }

      local gitctx = require 'gitctx'

      -- Branch files are opened as fugitive blob buffers (fugitive://<gitdir>//<sha>/<path>)
      -- rather than scratch buffers holding `git show` output. Fugitive already models "this
      -- file at this revision", so the branch stays checked out while `;sb` (git bcommits),
      -- `;vb` (:Git blame), :0Gclog, gf and dq all work against the right revision — see
      -- lua/gitctx.lua.

      -- The repo + file the cursor is sitting on in a raw `git diff` buffer, plus the branch
      -- names juniper_branch_diff() exported. Returns nil (after notifying) if anything of
      -- that is missing. `need_base` is false for the feature-only mapping.
      local function diff_target(need_base)
        local base = vim.env.JUNIPER_BASE_BRANCH
        local feat = vim.env.JUNIPER_FEATURE_BRANCH
        if not feat or feat == '' or (need_base and (not base or base == '')) then
          vim.notify('Run juniper_branch_diff first (sets JUNIPER_BASE/FEATURE_BRANCH)', vim.log.levels.WARN)
          return nil
        end
        local lnum = vim.fn.search('^+++ b/', 'bcnW')
        if lnum == 0 then
          vim.notify("Not inside a file diff block (no '+++ b/' line above cursor)", vim.log.levels.WARN)
          return nil
        end
        local gitdir = gitctx.gitdir_for_cwd()
        if not gitdir then
          return nil
        end
        local root = vim.fn.FugitiveWorkTree(gitdir)
        if root == '' then
          vim.notify('No work tree for ' .. gitdir, vim.log.levels.WARN)
          return nil
        end
        return { base = base, feat = feat, file = (vim.fn.getline(lnum):gsub('^%+%+%+ b/', '')), gitdir = gitdir, root = root }
      end

      -- Open the file whose diff is under/above the cursor in a 2-way vimdiff tab.
      -- Intended for use when reading `git diff` output piped into nvim via
      -- juniper_branch_diff(). That function exports JUNIPER_BASE_BRANCH and
      -- JUNIPER_FEATURE_BRANCH so these mappings don't need the branch names re-typed.
      local function open_diff_file()
        local t = diff_target(true)
        if not t then
          return
        end
        if not gitctx.open_blob(t.gitdir, t.feat, t.file, 'tabedit', 'feat') then
          return
        end
        -- Files added on the feature branch have no base side to diff against.
        if not gitctx.object_exists(t.root, t.base, t.file) then
          vim.notify(t.file .. ' does not exist in ' .. t.base .. ' (added on ' .. t.feat .. ')', vim.log.levels.INFO)
          return
        end
        -- splitright is off (init.lua), so the base side lands on the left.
        local ok, err = pcall(vim.cmd, 'Gvdiffsplit ' .. vim.fn.fnameescape(t.base .. ':' .. t.file))
        if not ok then
          vim.notify('Gvdiffsplit failed — ' .. tostring(err), vim.log.levels.WARN)
          return
        end
        vim.b.juniper_label = 'base'
        vim.cmd 'windo normal! gg'
      end

      local function open_feat_file()
        local t = diff_target(false)
        if not t then
          return
        end
        if gitctx.open_blob(t.gitdir, t.feat, t.file, 'tabedit', 'feat') then
          vim.cmd 'diffoff' -- a new tab inherits window options, incl. diff, from the window it was opened from
          vim.cmd 'normal! gg'
        end
      end

      -- <leader>df  in raw diff buffer: open feature-branch file in new tab (no diff mode)
      vim.keymap.set('n', '<leader>dL', open_feat_file, { desc = 'Juniper: open feature-branch file in new tab' })

      -- <leader>dF  in raw diff buffer: open file at cursor in 2-way vimdiff (new tab)
      vim.keymap.set('n', '<leader>dF', open_diff_file, { desc = 'Juniper: open diff file in 2-way vimdiff' })

      -- <leader>dJ  open DiffviewOpen panel for the stored Juniper branches
      vim.keymap.set('n', '<leader>dJ', function()
        local base = vim.env.JUNIPER_BASE_BRANCH
        local feat = vim.env.JUNIPER_FEATURE_BRANCH
        if not base or base == '' or not feat or feat == '' then
          vim.notify('Run juniper_branch_diff first (sets JUNIPER_BASE/FEATURE_BRANCH)', vim.log.levels.WARN)
          return
        end
        vim.cmd('DiffviewOpen ' .. base .. '...' .. feat)
      end, { desc = 'Juniper: DiffviewOpen panel for stored branches' })

      -- <leader>dq  close Diffview panel
      vim.keymap.set('n', '<leader>dq', '<cmd>DiffviewClose<CR>', { desc = 'Diffview: close panel' })
    end,
  },
}
