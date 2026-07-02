return {
  {
    'tpope/vim-fugitive',
    config = function()
      -- Close all diff windows from any pane (fugitive's dq only exists on blob side panes,
      -- not on the working file where you actually edit during 3-way merge resolution)
      vim.keymap.set('n', 'dq', function()
        if vim.wo.diff then
          vim.fn['fugitive#DiffClose']()
        end
      end, { silent = true, desc = 'Close diff windows' })
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
