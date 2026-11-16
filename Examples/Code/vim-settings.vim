" Minimal settings
set number relativenumber
set expandtab shiftwidth=4 tabstop=4
set ignorecase smartcase

let mapleader = " "
nnoremap <leader>w :write<CR>

function! TrimTrailing() abort
  let l:pos = getpos('.')
  %s/\s\+$//e
  call setpos('.', l:pos)
endfunction

autocmd BufWritePre *.py,*.go call TrimTrailing()
