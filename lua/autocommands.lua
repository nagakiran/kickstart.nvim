-- Useful when symlinked location is not part of gitrepo
vim.api.nvim_create_user_command('FollowSymLink', function()
  local resolved_path = vim.fn.resolve(vim.fn.expand '%')
  vim.cmd('file ' .. resolved_path)
  vim.cmd 'edit'
end, {})
