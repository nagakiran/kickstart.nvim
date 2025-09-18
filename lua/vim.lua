-- vim.cmd 'autocmd BufRead,BufNewFile /Users/nagakiran/textfiles/journals/*.txt set filetype=jrnl.txtfmt'

-- vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
--   pattern = '/Users/nagakiran/textfiles/journals/*.txt',
--   command = 'set filetype=jrnl.txtfmt',
-- })
-- vim.cmd([[
--   autocmd BufRead,BufNewFile ~/textfiles/journals/*.txt set filetype=jrnl.txtfmt
--   ]])
