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
      vim.g.taskwiki_sort_orders = {
        T = 'project+,due-',
        P = 'priority+',
      }
    end,
  },
  {
    'wakatime/vim-wakatime',
  },
  {
    'jbyuki/venn.nvim',
    config = function()
      -- venn.nvim: enable or disable keymappings
      function _G.Toggle_venn()
        local venn_enabled = vim.inspect(vim.b.venn_enabled)
        if venn_enabled == 'nil' then
          vim.b.venn_enabled = true
          vim.cmd [[setlocal ve=all]]
          -- draw a line on HJKL keystokes
          vim.api.nvim_buf_set_keymap(0, 'n', 'J', '<C-v>j:VBox<CR>', { noremap = true })
          vim.api.nvim_buf_set_keymap(0, 'n', 'K', '<C-v>k:VBox<CR>', { noremap = true })
          vim.api.nvim_buf_set_keymap(0, 'n', 'L', '<C-v>l:VBox<CR>', { noremap = true })
          vim.api.nvim_buf_set_keymap(0, 'n', 'H', '<C-v>h:VBox<CR>', { noremap = true })
          -- draw a box by pressing "f" with visual selection
          vim.api.nvim_buf_set_keymap(0, 'v', 'f', ':VBox<CR>', { noremap = true })
        else
          vim.cmd [[setlocal ve=]]
          vim.api.nvim_buf_del_keymap(0, 'n', 'J')
          vim.api.nvim_buf_del_keymap(0, 'n', 'K')
          vim.api.nvim_buf_del_keymap(0, 'n', 'L')
          vim.api.nvim_buf_del_keymap(0, 'n', 'H')
          vim.api.nvim_buf_del_keymap(0, 'v', 'f')
          vim.b.venn_enabled = nil
        end
      end
      -- toggle keymappings for venn using <leader>v
      vim.api.nvim_set_keymap('n', '<leader>zv', ':lua Toggle_venn()<CR>', { noremap = true })
    end,
  },
  {
    'kristijanhusak/vim-dadbod-ui',
    dependencies = {
      { 'tpope/vim-dadbod', lazy = true },
      { 'kristijanhusak/vim-dadbod-completion', ft = { 'sql', 'mysql', 'plsql' }, lazy = true }, -- Optional
    },
    cmd = {
      'DBUI',
      'DBUIToggle',
      'DBUIAddConnection',
      'DBUIFindBuffer',
    },
    init = function()
      -- Your DBUI configuration
      vim.g.db_ui_use_nerd_fonts = 1
    end,
  },
  {
    -- Had to do "yarn install" from ~/.local/share/nvim/lazy/markdown-preview.nvim/app
    'iamcco/markdown-preview.nvim',
    cmd = { 'MarkdownPreviewToggle', 'MarkdownPreview', 'MarkdownPreviewStop' },
    ft = { 'markdown' },
    build = function()
      vim.fn['mkdp#util#install']()
    end,
  },
  {
    'lambdalisue/vim-suda', -- An alternative sudo.vim for Vim and Neovim, limited support sudo in Windows
  },
  {
    -- Neovim treesitter plugin for setting the commentstring based on the cursor location in a file.
    'JoosepAlviste/nvim-ts-context-commentstring',
    opts = {
      enable_autocmd = false,
    },
  },
  {
    'HakonHarnes/img-clip.nvim',
    event = 'VeryLazy',
    opts = {
      -- add options here
      -- or leave it empty to use the default settings
      default = {
        file_name = function()
          local desctipion = vim.fn.input 'Description: '
          return desctipion:lower():gsub('[^a-z0-9]', '_')
        end,
        prompt_for_file_name = false,
      },
    },
    keys = {
      -- suggested keymap
      { '<leader>p', '<cmd>PasteImage<cr>', desc = 'Paste image from system clipboard' },
    },
  },
  {
    'junegunn/vim-easy-align', --A simple, easy-to-use Vim alignment plugin.
  },
  {
    'dhruvasagar/vim-table-mode', -- VIM Table Mode for instant table creation.
  },
  {
    'NvChad/nvim-colorizer.lua', -- The fastest Neovim colorizer
    event = 'BufReadPre',
    opts = { -- set to setup table
    },
  },
  {
    'benmills/vimux', -- vim plugin to interact with tmux
  },
  {
    'chrisbra/NrrwRgn',
  },
  {
    'Lokaltog/vim-easymotion',
  },
  {
    'chentoast/marks.nvim', -- A better user experience for viewing and interacting with Vim marks.
    event = 'VeryLazy',
    opts = {
      bookmark_0 = {
        sign = '⚑',
        virt_text = 'hello world',
        -- explicitly prompt for a virtual line annotation when setting a bookmark from this group.
        -- defaults to false.
        annotate = true,
      },
      mappings = {
        -- toogle_bookmark0 = 'mt0',
        -- To go to next bookmark
        next_bookmark0 = 'mn0',
      },
    },
  },
  {
    -- Make sure to set this up properly if you have lazy=true		[copied from avante dependencies]
    'MeanderingProgrammer/render-markdown.nvim',
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
      -- vim.g.rooter_patterns = { '.vim_rooter', 'setup.py', '.git' }
      -- setting setup.py doesn't work in most cases especially when working with monorepos and better use .vim_rooter for exceptional cases
      vim.g.rooter_patterns = { '.vim_rooter', '.git' }
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
      -- vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
      --   pattern = '*.txt',
      --   command = 'set filetype=txtfmt',
      -- })
    end,
  },
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    dependencies = {
      { 'github/copilot.vim' }, -- or zbirenbaum/copilot.lua
      { 'nvim-lua/plenary.nvim', branch = 'master' }, -- for curl, log and async functions
    },
    build = 'make tiktoken', -- Only on MacOS or Linux
    opts = {
      -- See Configuration section for options
    },
    -- See Commands section for default commands if you want to lazy load on them
  },
}
