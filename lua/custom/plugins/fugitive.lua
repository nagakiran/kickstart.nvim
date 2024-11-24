return {
 'tpope/vim-fugitive', 
 {
    'shumphrey/fugitive-gitlab.vim',      -- A vim extension to fugitive.vim for GitLab support
    config = function()
      vim.g.fugitive_gitlab_domains = {'https://ssd-git.juniper.net','https://eng-gitlab.juniper.net','https://eng-hs-gitlab.juniper.net'}
   end
 }
}
