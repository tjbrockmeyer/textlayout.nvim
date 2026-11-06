" syntax/textlayout.vim
" Highlights the layout sigils and meta groups in the source file.

if exists('b:current_syntax')
  finish
endif

syntax match tlMeta      /{[^}]*}/
syntax match tlGrid      /@grid(\d\+\s*,\s*\d\+)/
syntax match tlSeparator /|/
syntax match tlGroup     /[\[\]]/
syntax match tlEscape    /\\[\\|\[\]{}]/

highlight default link tlMeta      Special
highlight default link tlGrid      Statement
highlight default link tlSeparator Delimiter
highlight default link tlGroup     Delimiter
highlight default link tlEscape    SpecialChar

let b:current_syntax = 'textlayout'
