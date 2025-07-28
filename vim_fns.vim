" Z - cd to recent / frequent directories
command! -nargs=* Z :call Z(<f-args>)
function! Z(...)
	" If not arguments are passed, show the selection list
	if a:0 == 0
    let list = split(system('fasd -dlR'), '\n')
    let path = inputlist(list)
  else
		let cmd = 'fasd -d -e printf'
		for arg in a:000
			let cmd = cmd . ' ' . arg
		endfor
		let path = system(cmd)
	endif
  if isdirectory(path)
    echo path
    exec 'lcd' fnameescape(path)
	else 
    exec 'e' fnameescape(path)
  endif
endfunction

imap <F2> <C-R>=strftime("%Y-%m-%d")<CR>
" As Fn key is not sending properly from wireless keyboard
imap <A-d> <C-R>=strftime("%Y-%m-%d")<CR>

" Earlier getting this functionality from vim-unimpaired 
nnoremap ]q :cne<CR>  
nnoremap [q :cpr<CR>
nnoremap ]l :lne<CR>  
nnoremap [l :lpr<CR>

" Use CTRL-S for saving, also in Insert mode
noremap <C-S>		:update<CR>
vnoremap <C-S>		<C-C>:update<CR>
inoremap <C-S>		<C-O>:update<CR>

" Version control
nnoremap <leader>vb :Git blame<cr>

autocmd BufRead,BufNewFile *.yang set foldmethod=indent
autocmd BufRead,BufNewFile *.ldgr set filetype=ledger
set shiftwidth=2  " For indentation
" Seeing it's bit distraction when highlight is done for all matches as eye attention scatters
set nohlsearch

" Open in sc-im when we hover a filepath in vim
map gS :call VimuxRunCommand('sc-im '. expand('<cWORD>'))<CR>

" Mappings for marks.nvim
nmap mt0 <Plug>(Marks-toggle-bookmark0)

" nnoremap gO :!open <cfile><CR>
" https://superuser.com/questions/386646/xdg-open-url-doesnt-open-the-website-in-my-default-browser/407675
" nnoremap gO :!xdg-open <cfile> & <CR>
nnoremap <expr> gO has('mac') ? ':!open <cfile><CR>' :  ':!xdg-open <cfile> & <CR>'

autocmd FileType sql,mysql,plsql lua require('cmp').setup.buffer({ sources = {{ name = 'vim-dadbod-completion' }} })

" Map <leader>zc to write the visually selected paragraph to /tmp/out.txt and execute it with bash
map <leader>zc vip:w !>/tmp/out.txt /bin/bash<CR><CR><CR>

" nnoremap <Leader>dd :<C-u>let @z=join(getline("'{", "'}"), "\n") \| call writefile(split(system("grep '^export ' " . expand('%:p')), "\n") + split(@z, "\n"), "/tmp/tmp_script.sh") \| execute '!bash /tmp/tmp_script.sh > /tmp/out.txt'<CR>
lua << EOF
function _G.execute_paragraph_with_exports()
    -- Get the current paragraph content
    local start_mark = vim.fn.getpos("'{")[2]
    local end_mark = vim.fn.getpos("'}")[2]
    local paragraph_content = table.concat(vim.fn.getline(start_mark, end_mark), "\n")
    
    -- Get export statements from current file
    local current_file = vim.fn.expand('%:p')
    local exports = vim.fn.system('grep "^export " ' .. current_file)
    
    -- Write combined content to temporary script
    local script_content = exports .. "\n" .. paragraph_content
    local tmp_script = '/tmp/tmp_script.sh'
    local f = io.open(tmp_script, 'w')
    f:write(script_content)
    f:close()
    
    -- Execute the script and format the output if it's JSON
    local raw_output = vim.fn.system('bash ' .. tmp_script)
    
    -- Try to format with jq, fallback to raw output if not JSON
    local formatted_output = vim.fn.system('echo ' .. vim.fn.shellescape(raw_output) .. ' | jq . 2>/dev/null || echo ' .. vim.fn.shellescape(raw_output))
    
    -- Write the formatted output to file
    local out_file = io.open('/tmp/out.txt', 'w')
    out_file:write(formatted_output)
    out_file:close()

end
EOF

nnoremap <Leader>dd :lua execute_paragraph_with_exports()<CR>

