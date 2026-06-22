return {
  {
    'sindrets/diffview.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory' },
    keys = {
      { '<leader>dF', desc = 'Juniper: open diff file in 2-way vimdiff' },
      { '<leader>dJ', desc = 'Juniper: DiffviewOpen for stored branches' },
      { '<leader>dq', desc = 'Diffview: close panel' },
    },
    config = function()
      require('diffview').setup { use_icons = false }

      -- Open the file whose diff is under/above the cursor in a 2-way vimdiff tab.
      -- Intended for use when reading `git diff` output piped into nvim via
      -- juniper_branch_diff(). That function exports JUNIPER_BASE_BRANCH and
      -- JUNIPER_FEATURE_BRANCH so these mappings don't need the branch names re-typed.
      local function open_diff_file()
        local base = vim.env.JUNIPER_BASE_BRANCH
        local feat = vim.env.JUNIPER_FEATURE_BRANCH
        if not base or base == '' or not feat or feat == '' then
          vim.notify('Run juniper_branch_diff first (sets JUNIPER_BASE/FEATURE_BRANCH)', vim.log.levels.WARN)
          return
        end
        local lnum = vim.fn.search('^+++ b/', 'bcnW')
        if lnum == 0 then
          vim.notify("Not inside a file diff block (no '+++ b/' line above cursor)", vim.log.levels.WARN)
          return
        end
        local file = vim.fn.getline(lnum):gsub('^%+%+%+ b/', '')

        -- left pane: base branch
        vim.cmd 'tabnew'
        vim.cmd('read !git show ' .. vim.fn.shellescape(base .. ':' .. file))
        vim.cmd 'normal! gg"_dd'
        vim.bo.buftype = 'nofile'
        vim.bo.bufhidden = 'wipe'
        vim.bo.swapfile = false
        vim.cmd('file ' .. vim.fn.fnamemodify(file, ':t') .. '[base]')
        vim.cmd 'diffthis'

        -- right pane: feature branch
        vim.cmd 'vertical rightbelow new'
        vim.cmd('read !git show ' .. vim.fn.shellescape(feat .. ':' .. file))
        vim.cmd 'normal! gg"_dd'
        vim.bo.buftype = 'nofile'
        vim.bo.bufhidden = 'wipe'
        vim.bo.swapfile = false
        vim.cmd('file ' .. vim.fn.fnamemodify(file, ':t') .. '[feat]')
        vim.cmd 'diffthis'

        vim.cmd 'windo normal! gg'
      end

      -- <leader>df  in raw diff buffer: open file at cursor in 2-way vimdiff (new tab)
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
