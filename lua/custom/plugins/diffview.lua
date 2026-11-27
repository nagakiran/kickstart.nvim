return {
  {
    -- A maintained fork of sindrets/diffview.nvim (same `diffview` Lua module and commands). It adds the
    -- `diff1_inline` layout, a unified diff in one window, which `<leader>du` toggles with the side-by-side one.
    'dlyongemallo/diffview-plus.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory' },
    keys = {
      { '<leader>dF', desc = 'Diff file at cursor in 2-way vimdiff (new tab)' },
      { '<leader>dL', desc = 'Open feature-side file in new tab' },
      { '<leader>dB', desc = 'Open base-side file in new tab' },
      { '<leader>dJ', desc = 'Juniper: DiffviewOpen for stored branches' },
      { '<leader>du', desc = 'Diffview: toggle split / unified layout' },
      { '<leader>dq', desc = 'Diffview: close panel' },
    },
    init = function()
      -- Intra-line highlighting of a changed line. Nvim 0.12 defaults 'diffopt' to inline:char, which marks
      -- single letters inside words ("disable[s]" vs "keep[s]") and is hard to read in prose and identifiers;
      -- word mode marks whole words. <leader>dw cycles word -> char -> none (only the line is marked) for the
      -- session, in every diff: the split layouts, :Gvdiffsplit and plain vimdiff through 'diffopt', and
      -- Diffview's unified layout, which has its own tokenizer, through vim.g.diffview_intraline (read by the
      -- patched module in config below).
      local modes = { 'word', 'char', 'none' }
      local function set_inline(mode)
        vim.g.diffview_intraline = mode
        if vim.fn.has 'nvim-0.12' == 1 then
          local parts = vim.tbl_filter(function(p)
            return not p:match '^inline:'
          end, vim.split(vim.o.diffopt, ',', { trimempty = true }))
          table.insert(parts, 'inline:' .. mode)
          vim.o.diffopt = table.concat(parts, ',')
        end
      end
      set_inline 'word'
      vim.keymap.set('n', '<leader>dw', function()
        local i = vim.fn.index(modes, vim.g.diffview_intraline) + 1 -- 0-based index, so this is the next mode's 1-based position
        local mode = modes[i % #modes + 1]
        set_inline(mode)
        vim.cmd 'diffupdate'
        -- The unified layout paints extmarks when a file opens, so repaint the one on screen.
        local lib = package.loaded['diffview.lib']
        local view = lib and lib.get_current_view()
        local layout = view and view.cur_layout
        if layout and layout._repaint then
          layout:_repaint()
        end
        vim.notify('Intra-line diff: ' .. mode)
      end, { desc = 'Diff: cycle intra-line highlight (word/char/none)' })
    end,
    config = function()
      -- Load a diffview module from the plugin's own source with `subs` ({ pattern, replacement, min_count })
      -- applied. The modules are required lazily, so a preload set here wins. If upstream changes the code and a
      -- pattern stops matching, the stock module loads unchanged.
      local function patch_module(modname, subs)
        package.preload[modname] = function()
          local path = vim.api.nvim_get_runtime_file('lua/' .. modname:gsub('%.', '/') .. '.lua', false)[1]
          assert(path, modname .. ' not found')
          local src = table.concat(vim.fn.readfile(path), '\n')
          for _, sub in ipairs(subs) do
            local n
            src, n = src:gsub(sub[1], sub[2])
            if n < (sub[3] or 1) then
              vim.notify_once(('diffview.lua: patch for %s no longer matches; using it unpatched'):format(modname), vim.log.levels.WARN)
              return dofile(path)
            end
          end
          return assert(load(src, '@' .. path))(modname)
        end
      end

      -- The file panel's tree indent is hardcoded (2 columns per level for folders, 2 more for files), which
      -- hides long filenames in a narrow panel. Cut it to 1 column per level, so a file sits 1 column right of
      -- its folder's name.
      patch_module('diffview.scene.views.diff.render', {
        { 'depth %* 2 %+ 2', 'depth + 1' },
        { 'depth %* 2', 'depth' }, -- folder indents and the selection-mark variants
      })

      -- The unified layout's intra-line marks follow <leader>dw (vim.g.diffview_intraline, see init above):
      -- 'word' never refines a replaced word down to its changed letters, 'none' skips the char overlay so the
      -- whole changed line keeps its DiffChange backdrop, 'char' is the plugin's own word-then-letter diff.
      patch_module('diffview.scene.inline_diff', {
        {
          'local function refinement_safe%(old_chars, new_chars, n_hunks%)\n',
          '%0  if vim.g.diffview_intraline == "word" then return false end\n',
        },
        {
          'local function render_char_highlights%(bufnr, new_row, old_line, new_line, inline_del, add_hl%)\n  local ranges = {}\n',
          '%0  if vim.g.diffview_intraline == "none" and old_line ~= new_line then return "noop", ranges end\n',
        },
      })

      -- The unified layout draws no +/- markers, so give its window a status column: the line number, then '-'
      -- on the deleted lines (virtual lines, v:virtnum < 0) and '+' on added or changed lines. The changed rows
      -- come from the hunks inline_diff caches per buffer after each render.
      function _G.DiffviewInlineStc()
        local win = vim.g.statusline_winid
        local buf = vim.api.nvim_win_get_buf(win)
        local wo = vim.wo[win]
        local width = (wo.number or wo.relativenumber) and math.max(wo.numberwidth - 1, #tostring(vim.api.nvim_buf_line_count(buf))) or 0
        if vim.v.virtnum < 0 then
          return string.rep(' ', width) .. ' %#Removed#-%* '
        elseif vim.v.virtnum > 0 then
          return string.rep(' ', width + 3)
        end
        local lnum = vim.v.lnum
        local num = ''
        if width > 0 then
          num = tostring(wo.relativenumber and vim.v.relnum ~= 0 and vim.v.relnum or lnum)
          num = string.rep(' ', width - #num) .. num
        end
        local mark = ' '
        local hunks = (package.loaded['diffview.scene.inline_diff'] or {})._hunks_by_buf
        for _, h in ipairs(hunks and hunks[buf] or {}) do
          if h[4] > 0 and lnum >= h[3] and lnum < h[3] + h[4] then
            mark = '%#Added#+%*'
            break
          end
        end
        return num .. ' ' .. mark .. ' '
      end
      local STC = '%!v:lua.DiffviewInlineStc()'
      local function set_statuscolumn(_, winid, ctx)
        if ctx.layout_name == 'diff1_inline' then
          vim.wo[winid][0].statuscolumn = STC
        elseif vim.wo[winid].statuscolumn == STC then
          vim.wo[winid][0].statuscolumn = '' -- the window was reused for a split layout
        end
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
      local gu = { 'n', 'gu', unified_diff, { desc = 'Unified git diff of this file in a new tab' } }

      -- Split or unified: the layout every Diffview opens with (alt-v from liveq, <leader>dJ, :DiffviewOpen,
      -- :DiffviewFileHistory). <leader>du (or diffview's own g<C-x>) flips the open view between the two and makes
      -- that the default from then on, remembered across sessions in stdpath('state')/diffview_layout.
      local SPLIT, UNIFIED = 'diff2_horizontal', 'diff1_inline'
      local layout_file = vim.fn.stdpath 'state' .. '/diffview_layout'
      local saved = vim.uv.fs_stat(layout_file) and vim.trim(table.concat(vim.fn.readfile(layout_file), ''))
      local layout = (saved == SPLIT or saved == UNIFIED) and saved or SPLIT

      local dv_config = require 'diffview.config'
      local function set_default_layout(name)
        local view_conf = dv_config.get_config().view
        view_conf.default.layout, view_conf.file_history.layout = name, name
        pcall(vim.fn.writefile, { name }, layout_file)
      end
      local function toggle_layout()
        local view = require('diffview.lib').get_current_view()
        local cur = view and view.cur_layout and view.cur_layout.class and view.cur_layout.class.name or dv_config.get_config().view.default.layout
        local next_layout = cur == UNIFIED and SPLIT or UNIFIED
        set_default_layout(next_layout)
        if view then
          require('diffview.actions').cycle_layout() -- the cycle list is just { SPLIT, UNIFIED }
        end
        vim.notify('Diffview layout: ' .. (next_layout == UNIFIED and 'unified' or 'split'))
      end
      local du = { 'n', '<leader>du', toggle_layout, { desc = 'Toggle split / unified layout' } }

      require('diffview').setup {
        use_icons = false,
        file_panel = { win_config = { width = 40 } },
        view = {
          default = { layout = layout },
          file_history = { layout = layout },
          cycle_layouts = { default = { SPLIT, UNIFIED } },
          -- Deleted lines as full-width red rows, like the split layout's, not just a red background on their text.
          inline = { deletion_highlight = 'full_width' },
        },
        hooks = { diff_buf_win_enter = set_statuscolumn },
        keymaps = { view = { gu, du }, diff1_inline = { gu, du }, file_panel = { gu, du }, file_history_panel = { gu, du } },
      }

      local gitctx = require 'gitctx'

      -- Branch files are opened as fugitive blob buffers (fugitive://<gitdir>//<sha>/<path>)
      -- rather than scratch buffers holding `git show` output. Fugitive already models "this
      -- file at this revision", so the branch stays checked out while `;sb` (git bcommits),
      -- `;vb` (:Git blame), :0Gclog, gf and dq all work against the right revision — see
      -- lua/gitctx.lua.

      -- What <leader>dF/dL/dB act on: the file the cursor is on, with the revision of each side.
      --   base, feat   revisions for fugitive ('' is the index; nil means the working tree)
      --   base_file    path on the base side (differs from `file` for a rename)
      --   gitdir, root the repository
      -- Inside a Diffview tab it comes from the current entry, so it works in DiffviewOpen and FileHistory alike.
      -- Elsewhere it is the `+++ b/` block above the cursor in a raw `git diff` buffer (liveq alt-d, or
      -- juniper_branch_diff), with the branches from $JUNIPER_BASE_BRANCH / $JUNIPER_FEATURE_BRANCH.
      local function diffview_target()
        local view = require('diffview.lib').get_current_view()
        if not view then
          return nil
        end
        local file = view:infer_cur_file()
        if not file or not file.revs or not file.revs.a or not file.revs.b then
          vim.notify('No diffview file entry here', vim.log.levels.WARN)
          return false
        end
        local RevType = require('diffview.vcs.rev').RevType
        local function rev(r)
          if r.type == RevType.COMMIT then
            return r.commit
          elseif r.type == RevType.STAGE then
            return ''
          end
        end
        local ctx = file.adapter.ctx
        return {
          base = rev(file.revs.a),
          feat = rev(file.revs.b),
          file = file.path,
          base_file = file.oldpath or file.path,
          gitdir = ctx.dir,
          root = ctx.toplevel,
        }
      end

      local function raw_diff_target(need_base)
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
        local file = (vim.fn.getline(lnum):gsub('^%+%+%+ b/', ''))
        local old = vim.fn.getline(lnum - 1):match '^%-%-%- a/(.*)' -- '--- /dev/null' for an added file
        return { base = base, feat = feat, file = file, base_file = old or file, gitdir = gitdir, root = root }
      end

      local function diff_target(need_base)
        local t = diffview_target()
        if t == nil then
          return raw_diff_target(need_base)
        end
        return t or nil
      end

      -- Open one side of the target in a new tab: a fugitive blob for a revision, the file itself for the
      -- working tree. Returns true on success.
      local function open_side(t, side)
        local rev, path, label = t.feat, t.file, 'feat'
        if side == 'base' then
          rev, path, label = t.base, t.base_file, 'base'
        end
        if rev == nil then
          vim.cmd('tabedit ' .. vim.fn.fnameescape(t.root .. '/' .. path))
        elseif not gitctx.object_exists(t.root, rev, path) then
          vim.notify(('%s does not exist on the %s side (%s)'):format(path, label, rev == '' and 'index' or rev), vim.log.levels.INFO)
          return false
        elseif not gitctx.open_blob(t.gitdir, rev, path, 'tabedit', label) then
          return false
        end
        vim.cmd 'diffoff' -- a new tab inherits window options, incl. diff, from the window it was opened from
        return true
      end

      -- Open the file at the cursor in a 2-way fugitive vimdiff tab (base left, feature right), so that blame,
      -- :0Gclog and the rest of fugitive work against the right revisions.
      local function open_diff_file()
        local t = diff_target(true)
        if not t or not open_side(t, 'feat') then
          return
        end
        if t.base ~= nil and not gitctx.object_exists(t.root, t.base, t.base_file) then
          vim.notify(t.base_file .. ' does not exist on the base side (added on ' .. (t.feat or 'the working tree') .. ')', vim.log.levels.INFO)
          return
        end
        -- splitright is off (init.lua), so the base side lands on the left.
        local spec = t.base == nil and (t.root .. '/' .. t.base_file) or (t.base .. ':' .. t.base_file)
        local ok, err = pcall(vim.cmd, 'Gvdiffsplit ' .. vim.fn.fnameescape(spec))
        if not ok then
          vim.notify('Gvdiffsplit failed — ' .. tostring(err), vim.log.levels.WARN)
          return
        end
        vim.b.juniper_label = 'base'
        vim.cmd 'windo normal! gg'
      end

      local function open_file(side)
        return function()
          local t = diff_target(side == 'base')
          -- Keep the cursor's line when it sits in the Diffview window showing that same side (the unified
          -- layout shows only the feature side).
          local lnum = vim.fn.line '.'
          local view = t and require('diffview.lib').get_current_view()
          local cur = view and view.cur_layout
          local win = cur and (side == 'base' and cur.a or cur.b)
          local same = win and win.id == vim.api.nvim_get_current_win()
          if t and open_side(t, side) then
            vim.cmd(same and ('normal! ' .. lnum .. 'Gzz') or 'normal! gg')
          end
        end
      end

      vim.keymap.set('n', '<leader>dL', open_file 'feat', { desc = 'Open feature-side file at cursor in new tab' })
      vim.keymap.set('n', '<leader>dB', open_file 'base', { desc = 'Open base-side file at cursor in new tab' })
      vim.keymap.set('n', '<leader>dF', open_diff_file, { desc = 'Diff file at cursor in 2-way vimdiff (new tab)' })

      -- <leader>dJ  open DiffviewOpen for the stored Juniper branches, on the file under the cursor if in a raw diff
      vim.keymap.set('n', '<leader>dJ', function()
        local base = vim.env.JUNIPER_BASE_BRANCH
        local feat = vim.env.JUNIPER_FEATURE_BRANCH
        if not base or base == '' or not feat or feat == '' then
          vim.notify('Run juniper_branch_diff first (sets JUNIPER_BASE/FEATURE_BRANCH)', vim.log.levels.WARN)
          return
        end
        local cmd = 'DiffviewOpen ' .. base .. '...' .. feat
        local lnum = vim.bo.filetype == 'diff' and vim.fn.search('^+++ b/', 'bcnW') or 0
        if lnum > 0 then
          cmd = cmd .. ' --selected-file=' .. vim.fn.fnameescape((vim.fn.getline(lnum):gsub('^%+%+%+ b/', '')))
        end
        vim.cmd(cmd)
      end, { desc = 'Juniper: DiffviewOpen panel for stored branches' })

      -- <leader>dq  close Diffview panel
      vim.keymap.set('n', '<leader>dq', '<cmd>DiffviewClose<CR>', { desc = 'Diffview: close panel' })
    end,
  },
}
