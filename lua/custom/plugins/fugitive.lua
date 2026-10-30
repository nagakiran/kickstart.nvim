return {
  {
    -- Fork: upstream plus g:fugitive_summary_log_columns (set in init.lua). The fork's master is
    -- an unrelated 2016 branch, so the patch lives on 'personal'; rebase it onto tpope's master to update.
    'nagakiran/vim-fugitive',
    branch = 'personal',
    config = function()
      -- Close all diff windows from any pane (fugitive's dq only exists on blob side panes,
      -- not on the working file where you actually edit during 3-way merge resolution)
      vim.keymap.set('n', 'dq', function()
        if vim.wo.diff then
          vim.fn['fugitive#DiffClose']()
        end
      end, { silent = true, desc = 'Close diff windows' })

      -- :GBrowse hands the URL to :Browse when one exists, and only falls back to netrw
      -- otherwise. nvim 0.12's netrw narrowed netrw#BrowseX(fname, remote) to
      -- netrw#BrowseX(fname), but fugitive still calls it with two arguments — so that
      -- fallback dies with E118 and the browser never opens. Route it through vim.ui.open.
      -- (nargs=1 args arrive raw, so '#L10' anchors survive.)
      vim.api.nvim_create_user_command('Browse', function(opts)
        vim.ui.open(opts.args)
      end, { nargs = 1, desc = 'Open a URL (used by fugitive :GBrowse)' })
    end,
  },
  {
    'shumphrey/fugitive-gitlab.vim', -- A vim extension to fugitive.vim for GitLab support
    config = function()
      vim.g.fugitive_gitlab_domains = { 'https://ssd-git.juniper.net', 'https://eng-gitlab.juniper.net', 'https://eng-hs-gitlab.juniper.net' }
    end,
  },
  {
    'tpope/vim-rhubarb',
  },
}
