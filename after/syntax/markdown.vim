" syntax match MyBold /\*\*[^*]\+\*\*/
" highlight MyBold cterm=bold gui=bold guifg=Yellow
syntax match AtWord /@\w\+/
highlight AtWord ctermfg=Yellow guifg=Yellow

syn match   txtfmtLineComment      "@#.*" 
highlight link txtfmtLineComment Comment
syn match   txtfmtHyperlink      /http[s]\?:\/\/[^ ]*/
highlight link txtfmtHyperlink Underlined
