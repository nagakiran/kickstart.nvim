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
