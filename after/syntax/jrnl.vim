if exists("b:current_syntax")
    finish
endif

syntax match jtag "@.\{-}\w\+"
syntax match jyear /\d\{4}-\d\d-\d\d \d\d:\d\d/

syntax region entryLine start=/\d\{4}-\d\d-\d\d \d\d:\d\d/ end=/$/ contains=jyear

highlight def link jtag Constant
highlight def link jyear Identifier
highlight def entryLine ctermfg=250 guifg=Gray

let b:current_syntax = "jrnl"
