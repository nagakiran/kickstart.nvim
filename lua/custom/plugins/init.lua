-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information
return {
  {
    -- 'tbabej/taskwiki',
    'nagakiran/taskwiki',
    event = 'VimEnter',
    dependencies = { 'vimwiki/vimwiki' },
    opts = {},
    config = function()
      vim.g.taskwiki_extra_warriors = {
        D = { data_location = '~/textfiles/tasks/demattasks/', taskrc_location = '~/rcfiles/.demattaskrc' },
        S = { data_location = '~/textfiles/tasks/selftasks/', taskrc_location = '~/rcfiles/.selftaskrc' },
        C = { data_location = '~/bitbucket/contrailtask/', taskrc_location = '~/rcfiles/.demattaskrc' },
        V = { data_location = '~/textfiles/tasks/viamaan/', taskrc_location = '~/rcfiles/.viamaantaskrc' },
        H = { data_location = '~/textfiles/tasks/hpetasks/', taskrc_location = '~/rcfiles/.hpetaskrc' },
        J = { data_location = '~/textfiles/tasks/junipertasks/', taskrc_location = '~/rcfiles/.junipertaskrc' },
        T = { data_location = '~/textfiles/tasks/tracktasks/', taskrc_location = '~/rcfiles/.tracktaskrc' },
      }
    end,
  },
  {
    'wakatime/vim-wakatime',
  },
  {
    'benmills/vimux'         -- vim plugin to interact with tmux
  },
  {
    'chrisbra/NrrwRgn',
  },
  {
    'Lokaltog/vim-easymotion',
  },
  {
    'zenbro/mirror.vim', -- Efficient way to edit remote files on multiple environments with Vim.
  },
  {
    'vim-scripts/DirDiff.vim', -- A plugin to diff and merge two directories recursively.
  },
  {
    'vim-scripts/CmdlineComplete', -- complete command-line (: / etc.) from the current file
  },
  {
    'airblade/vim-rooter', -- Changes Vim working directory to project root (identified by presence of known directory or file).
    config = function()
      vim.g.rooter_patterns = { '.vim_rooter', 'setup.py', '.git' }
      -- let g:rooter_patterns = ['.ctrlp','.git/']

      vim.g.rooter_cd_cmd = 'lcd' -- To change directory for the current window only (:lcd)
      vim.g.rooter_silent_chdir = 1 -- To stop vim-rooter echoing the project directory
      -- Disable changing directory for vim-fugitive
      -- autocmd BufEnter * if index(['help', 'nofile', 'terminal','fugitive'], &buftype) >= 0 | let b:rooter_silent_chdir = 1 | endif
      -- Create an autocommand group
      local group = vim.api.nvim_create_augroup('RooterSilentChdir', { clear = true })

      -- Define the autocommand
      vim.api.nvim_create_autocmd('BufEnter', {
        group = group,
        pattern = '*',
        callback = function()
          local buftype = vim.api.nvim_buf_get_option(0, 'buftype')
          if vim.tbl_contains({ 'help', 'nofile', 'terminal', 'fugitive' }, buftype) then
            vim.b.rooter_silent_chdir = 1
          end
        end,
      })
    end,
  },
  {
    'bpstahlman/txtfmt', -- Txtfmt (The Vim Highlighter) : "Rich text" highlighting in Vim! (colors, underline, bold, italic, etc...)
    config = function()
      vim.g.txtfmtMapwarn = 'c'
      vim.g.txtfmtShortcuts = { ',b fbu cr' }
      vim.g.txtfmtTokrange = '180S'
      -- Disabling it as it conflicts with right-shift and repeat opeator
      vim.g.txtfmtLeadingindent = 'none'
      vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
        pattern = '*.txt',
        command = 'set filetype=txtfmt',
      })
    end,
  },
}
