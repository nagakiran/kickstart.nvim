--[[

=====================================================================
==================== READ THIS BEFORE CONTINUING ====================
=====================================================================
========                                    .-----.          ========
========         .----------------------.   | === |          ========
========         |.-""""""""""""""""""-.|   |-----|          ========
========         ||                    ||   | === |          ========
========         ||   KICKSTART.NVIM   ||   |-----|          ========
========         ||                    ||   | === |          ========
========         ||                    ||   |-----|          ========
========         ||:Tutor              ||   |:::::|          ========
========         |'-..................-'|   |____o|          ========
========         `"")----------------(""`   ___________      ========
========        /::::::::::|  |::::::::::\  \ no mouse \     ========
========       /:::========|  |==hjkl==:::\  \ required \    ========
========      '""""""""""""'  '""""""""""""'  '""""""""""'   ========
========                                                     ========
=====================================================================
=====================================================================

What is Kickstart?

  Kickstart.nvim is *not* a distribution.

  Kickstart.nvim is a starting point for your own configuration.
    The goal is that you can read every line of code, top-to-bottom, understand
    what your configuration is doing, and modify it to suit your needs.

    Once you've done that, you can start exploring, configuring and tinkering to
    make Neovim your own! That might mean leaving Kickstart just the way it is for a while
    or immediately breaking it into modular pieces. It's up to you!

    If you don't know anything about Lua, I recommend taking some time to read through
    a guide. One possible example which will only take 10-15 minutes:
      - https://learnxinyminutes.com/docs/lua/

    After understanding a bit more about Lua, you can use `:help lua-guide` as a
    reference for how Neovim integrates Lua.
    - :help lua-guide
    - (or HTML version): https://neovim.io/doc/user/lua-guide.html

Kickstart Guide:

  TODO: The very first thing you should do is to run the command `:Tutor` in Neovim.

    If you don't know what this means, type the following:
      - <escape key>
      - :
      - Tutor
      - <enter key>

    (If you already know the Neovim basics, you can skip this step.)

  Once you've completed that, you can continue working through **AND READING** the rest
  of the kickstart init.lua.

  Next, run AND READ `:help`.
    This will open up a help window with some basic information
    about reading, navigating and searching the builtin help documentation.

    This should be the first place you go to look when you're stuck or confused
    with something. It's one of my favorite Neovim features.

    MOST IMPORTANTLY, we provide a keymap "<space>sh" to [s]earch the [h]elp documentation,
    which is very useful when you're not exactly sure of what you're looking for.

  I have left several `:help X` comments throughout the init.lua
    These are hints about where to find more information about the relevant settings,
    plugins or Neovim features used in Kickstart.

   NOTE: Look for lines like this

    Throughout the file. These are for you, the reader, to help you understand what is happening.
    Feel free to delete them once you know what you're doing, but they should serve as a guide
    for when you are first encountering a few different constructs in your Neovim config.

If you experience any errors while trying to install kickstart, run `:checkhealth` for more info.

I hope you enjoy your Neovim journey,
- TJ

P.S. You can delete this when you're done too. It's your config now! :)
--]]

-- custom shell
-- vim.o.shell = '/opt/homebrew/bin/bash --norc'

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ';'
vim.g.maplocalleader = ';'

-- Set the background to light as using solarized8 light  (vim.g didn't work??)
-- Not needed as switching to dracula theme in iTerm2
-- vim.opt.background = 'light'
vim.opt.background = 'dark'
-- To prevent Neovim from wrapping lines within a word
vim.opt.linebreak = true

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- To auto-reload file when changed from elsewhere
vim.opt.autoread = true
-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
-- vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
  -- [ ] Problem is that generally copy from Mac and then come to vim to delete text to replace but thats overriding clipboard selection
  -- vim.opt.clipboard = 'unnamedplus'
end)

-- Enable break indent
-- Don't wrapped lines visually indented to align with the indentation of the original line
vim.opt.breakindent = false

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
-- Displays which-key popup sooner
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
-- Disabling these two as used to have :Git window at top and codecompanion.nvim window left
-- vim.opt.splitright = true
-- vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = false
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
-- [ ] Not used to seeing cursorline and enable when see any usecase
vim.opt.cursorline = false

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
-- vim.keymap.set('i', '<Tab>', function()
--   if require('supermaven-nvim').has_suggestion() then
--     require('supermaven-nvim').accept_suggestion()
--   elseif vim.fn['vsnip#available'](1) == 1 then
--     return '<Plug>(vsnip-expand-or-jump)'
--   else
--     return '<Tab>'
--   end
-- end, { expr = true, silent = true })

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
-- Will be useful to look at diagnostic messages that spawn across a line [also for copying as virtual text can't be copied]
vim.keymap.set('n', '<leader>df', vim.diagnostic.open_float, { desc = 'Open diagnostic [F]loat' })
vim.keymap.set('n', ']e', function()
  vim.diagnostic.goto_next { severity = vim.diagnostic.severity.ERROR }
end, { desc = 'Next [E]rror diagnostic' })
vim.keymap.set('n', '[e', function()
  vim.diagnostic.goto_prev { severity = vim.diagnostic.severity.ERROR }
end, { desc = 'Previous [E]rror diagnostic' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- TIP: Disable arrow keys in normal mode
-- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
-- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
-- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
-- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
--  [ ] As comfortable with default mappings??
-- vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
-- vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
-- vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
-- vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- Add this autocmd to clear virtual text on mode changes
vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
  callback = function()
    require('copilot.suggestion').dismiss()
  end,
})

-- [[ Install `lazy.nvim` plugin manager ]]
--    See `:help lazy.nvim.txt` or https://github.com/folke/lazy.nvim for more info
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
  if vim.v.shell_error ~= 0 then
    error('Error cloning lazy.nvim:\n' .. out)
  end
end ---@diagnostic disable-next-line: undefined-field
vim.opt.rtp:prepend(lazypath)

-- Custom tabline to show tabnr in title
require 'tabline'
require 'globals'
require 'autocommands'
require 'vim'

-- [[ Configure and install plugins ]]
--
--  To check the current status of your plugins, run
--    :Lazy
--
--  You can press `?` in this menu for help. Use `:q` to close the window
--
--  To update plugins you can run
--    :Lazy update
--
-- NOTE: Here is where you install your plugins.
require('lazy').setup({
  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  -- [ ] sometimes noticed detecting incorrectly like in ledger files
  -- 'tpope/vim-sleuth', -- Detect tabstop and shiftwidth automatically

  -- Automatic GPG file handling
  { 'jamessan/vim-gnupg' },

  -- NOTE: Plugins can also be added by using a table,
  -- with the first argument being the link and the following
  -- keys can be used to configure plugin behavior/loading/etc.
  --
  -- Use `opts = {}` to force a plugin to be loaded.
  --

  -- Here is a more advanced example where we pass configuration
  -- options to `gitsigns.nvim`. This is equivalent to the following Lua:
  --    require('gitsigns').setup({ ... })
  --
  -- See `:help gitsigns` to understand what the configuration keys do
  { -- Adds git related signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },

  -- NOTE: Plugins can also be configured to run Lua code when they are loaded.
  --
  -- This is often very useful to both group configuration, as well as handle
  -- lazy loading plugins that don't need to be loaded immediately at startup.
  --
  -- For example, in the following configuration, we use:
  --  event = 'VimEnter'
  --
  -- which loads which-key before all the UI elements are loaded. Events can be
  -- normal autocommands events (`:help autocmd-events`).
  --
  -- Then, because we use the `config` key, the configuration only runs
  -- after the plugin has been loaded:
  --  config = function() ... end

  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    opts = {
      icons = {
        -- set icon mappings to true if you have a Nerd Font
        mappings = vim.g.have_nerd_font,
        -- If you are using a Nerd Font: set icons.keys to an empty table which will use the
        -- default which-key.nvim defined Nerd Font icons, otherwise define a string table
        keys = vim.g.have_nerd_font and {} or {
          Up = '<Up> ',
          Down = '<Down> ',
          Left = '<Left> ',
          Right = '<Right> ',
          C = '<C-…> ',
          M = '<M-…> ',
          D = '<D-…> ',
          S = '<S-…> ',
          CR = '<CR> ',
          Esc = '<Esc> ',
          ScrollWheelDown = '<ScrollWheelDown> ',
          ScrollWheelUp = '<ScrollWheelUp> ',
          NL = '<NL> ',
          BS = '<BS> ',
          Space = '<Space> ',
          Tab = '<Tab> ',
          F1 = '<F1>',
          F2 = '<F2>',
          F3 = '<F3>',
          F4 = '<F4>',
          F5 = '<F5>',
          F6 = '<F6>',
          F7 = '<F7>',
          F8 = '<F8>',
          F9 = '<F9>',
          F10 = '<F10>',
          F11 = '<F11>',
          F12 = '<F12>',
        },
      },

      -- Document existing key chains
      spec = {
        { '<leader>c', group = '[C]ode', mode = { 'n', 'x' } },
        { '<leader>d', group = '[D]ocument' },
        { '<leader>r', group = '[R]ename' },
        { '<leader>s', group = '[S]earch' },
        { '<leader>w', group = '[W]orkspace' },
        { '<leader>t', group = '[T]oggle' },
        { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
      },
    },
  },

  -- NOTE: Plugins can specify dependencies.
  --
  -- The dependencies are proper plugin specifications as well - anything
  -- you do for a plugin at the top level, you can do for a dependency.
  --
  -- Use the `dependencies` key to specify the dependencies of a particular plugin

  { -- Autoformat
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>f',
        function()
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = false,
      format_on_save = function(bufnr)
        -- Disable "format_on_save lsp_fallback" for languages that don't
        -- have a well standardized coding style. You can add additional
        -- languages here or re-enable it for the disabled ones.
        local disable_filetypes = { c = true, cpp = true }
        local lsp_format_opt
        if disable_filetypes[vim.bo[bufnr].filetype] then
          lsp_format_opt = 'never'
        else
          lsp_format_opt = 'fallback'
        end
        return {
          -- Increasing the timeout as getting timeout error sometimes
          timeout_ms = 5000,
          lsp_format = lsp_format_opt,
        }
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        -- Conform can also run multiple formatters sequentially
        python = { 'isort', 'black' },
        --
        -- You can use 'stop_after_first' to run the first available formatter from the list
        javascript = { 'prettierd', 'prettier', stop_after_first = true },
        -- Tried for ways to set same config for multiple filetypes but not working
        -- [ "typescriptreact,typescript" ] = { 'prettierd', 'prettier', stop_after_first = true },
        typescript = { 'prettierd', 'prettier', stop_after_first = true },
        typescriptreact = { 'prettierd', 'prettier', stop_after_first = true },
        json = { 'prettierd', 'prettier', stop_after_first = true },
        jsonc = { 'prettierd', 'prettier', stop_after_first = true },
        less = { 'prettierd', 'prettier', stop_after_first = true },
        -- goimports runs gofmt + organises imports in one pass
        go = { 'goimports', stop_after_first = true },
      },
    },
  },

  -- { -- You can easily change to a different colorscheme.
  --   -- Change the name of the colorscheme plugin below, and then
  --   -- change the command in the config to whatever the name of that colorscheme is.
  --   --
  --   -- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`.
  --   'folke/tokyonight.nvim',
  --   priority = 1000, -- Make sure to load this before all the other start plugins.
  --   init = function()
  --     -- Load the colorscheme here.
  --     -- Like many other themes, this one has different styles, and you could load
  --     -- any other, such as 'tokyonight-storm', 'tokyonight-moon', or 'tokyonight-day'.
  --     -- vim.cmd.colorscheme 'tokyonight-night'
  --
  --     -- You can configure highlights by doing something like:
  --     vim.cmd.hi 'Comment gui=none'
  --   end,
  -- },
  --{
  --  'lifepillar/vim-solarized8',
  --  priority = 1000, -- Make sure to load this before all the other start plugins.
  --  init = function()
  --    vim.cmd.colorscheme 'solarized8'
  --  end,
  --},
  {
    'dracula/vim',
    priority = 1000, -- Make sure to load this before all the other start plugins.
    init = function()
      -- vim.cmd.colorscheme 'dracula'
    end,
  },
  {
    'morhetz/gruvbox',
    priority = 1000,
    init = function()
      -- vim.opt.background = 'dark' -- or 'light' if you prefer
      vim.cmd.colorscheme 'gruvbox'
    end,
  },

  -- Highlight todo, notes, etc in comments
  { 'folke/todo-comments.nvim', event = 'VimEnter', dependencies = { 'nvim-lua/plenary.nvim' }, opts = { signs = false } },

  { -- Collection of various small independent plugins/modules
    'echasnovski/mini.nvim',
    config = function()
      -- Better Around/Inside textobjects
      --
      -- Examples:
      --  - va)  - [V]isually select [A]round [)]paren
      --  - yinq - [Y]ank [I]nside [N]ext [Q]uote
      --  - ci'  - [C]hange [I]nside [']quote
      require('mini.ai').setup { n_lines = 500 }

      -- Add/delete/replace surroundings (brackets, quotes, etc.)
      --
      -- - saiw) - [S]urround [A]dd [I]nner [W]ord [)]Paren
      -- - sd'   - [S]urround [D]elete [']quotes
      -- - sr)'  - [S]urround [R]eplace [)] [']
      require('mini.surround').setup()

      -- Simple and easy statusline.
      --  You could remove this setup call if you don't like it,
      --  and try some other statusline plugin
      -- local statusline = require 'mini.statusline'
      -- -- set use_icons to true if you have a Nerd Font
      -- statusline.setup { use_icons = vim.g.have_nerd_font }

      -- -- You can configure sections in the statusline by overriding their
      -- -- default behavior. For example, here we set the section for
      -- -- cursor location to LINE:COLUMN
      -- ---@diagnostic disable-next-line: duplicate-set-field
      -- statusline.section_location = function()
      --   return '%2l:%-2v'
      -- end

      -- ... and there is more!
      --  Check out: https://github.com/echasnovski/mini.nvim
    end,
  },
  -- The following comments only work if you have downloaded the kickstart repo, not just copy pasted the
  -- init.lua. If you want these files, they are in the repository, so you can just download them and
  -- place them in the correct locations.

  -- NOTE: Next step on your Neovim journey: Add/Configure additional plugins for Kickstart
  --
  --  Here are some example plugins that I've included in the Kickstart repository.
  --  Uncomment any of the lines below to enable them (you will need to restart nvim).
  --
  require 'kickstart.plugins.debug',
  -- require 'kickstart.plugins.indent_line',
  -- require 'kickstart.plugins.lint',
  -- require 'kickstart.plugins.autopairs',
  -- require 'kickstart.plugins.neo-tree',
  require 'kickstart.plugins.gitsigns', -- adds gitsigns recommend keymaps

  -- NOTE: The import below can automatically add your own plugins, configuration, etc from `lua/custom/plugins/*.lua`
  --    This is the easiest way to modularize your config.
  --
  --  Uncomment the following line and add your plugins to `lua/custom/plugins/*.lua` to get going.
  { import = 'custom.plugins' },
  --
  -- For additional information with loading, sourcing and examples see `:help lazy.nvim-🔌-plugin-spec`
  -- Or use telescope!
  -- In normal mode type `<space>sh` then write `lazy.nvim-plugin`
  -- you can continue same window with `<space>sr` which resumes last telescope search
}, {
  change_detection = {
    -- Re-enable whenever see any use case, as especially when we edit 10 times, changes get stacked and see notification 10 times
    notify = false, -- disable notifications when changes are detected
  },
  ui = {
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})
vim.cmd [[
  autocmd BufRead,BufNewFile ~/textfiles/*.txt set filetype=markdown
	" Need to add it explicitly as looks based markdown syntax file is not loaded automatically and treesitter/render-markdown syntax is getting loaded
	autocmd FileType markdown source ~/.config/nvim/after/syntax/markdown.vim
  " autocmd BufRead,BufNewFile ~/textfiles/journals/*.txt set filetype=markdown.jrnl.txtfmt
  au BufNewFile,BufRead *.tjp,*.tji               setf tjp
  ]]
-- Relative path not working and need to be checked
vim.cmd 'source ~/.config/nvim/vim_fns.vim'

-- CodeCompanion keymaps are now defined in lua/custom/plugins/codecompanion.lua

-- This is working fine when tab containing the file is not in focus and switch to that tab, it's refreshing?
-- vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, {
-- will check for file changes whenever the cursor is idle (i.e., not moving) for a short period.
vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
  pattern = '*',
  callback = function()
    -- check added to address error that checktime is not valid in command-line window
    if vim.api.nvim_get_mode().mode == 'n' and vim.fn.getcmdwintype() == '' then
      vim.cmd 'checktime'
    end
  end,
  -- command = 'checktime',
})

-- Automatically stop LSP clients when the buffer is deleted
-- -- Enable back when reuired with proper comments for adding this as ideally nvim LSP client handles buffer cleanup automatically (faced issue as copilot LSP is global across buffers and due to this it's stopping)
-- vim.api.nvim_create_autocmd('BufDelete', {
--   callback = function(args)
--     local bufnr = args.buf
--     local clients = vim.lsp.get_clients { bufnr = bufnr }
--     for _, client in ipairs(clients) do
--       -- Detach the buffer, don't stop the client
--			 -- if vim.lsp.buf_is_attached(bufnr, client.id) then
--			 --   vim.lsp.buf_detach_client(bufnr, client.id)
--			 -- end
--			 -- Don't stop global clients like Copilot
-- 			 --	if client.name ~= 'copilot' then
--       --   vim.lsp.buf_detach_client(bufnr, client.id)
--       -- end
--       client.stop()
--     end
--   end,
-- })

-- As copilot.lua is not loaded by default for codecompanion filetype, we need to enable it manually
-- vim.api.nvim_create_autocmd('FileType', {
--   pattern = 'codecompanion', -- replace with your actual filetype
--   callback = function()
--     vim.cmd 'Copilot enable'
--   end,
-- })

-- https://github.com/JoosepAlviste/nvim-ts-context-commentstring/wiki/Integrations
local get_option = vim.filetype.get_option
vim.filetype.get_option = function(filetype, option)
  return option == 'commentstring' and require('ts_context_commentstring.internal').calculate_commentstring() or get_option(filetype, option)
end

-- Mapping to copy all messages to clipboard
vim.keymap.set('n', '<leader>mc', function()
  local messages = vim.api.nvim_exec2('messages', { output = true }).output
  vim.fn.setreg('+', messages)
  vim.notify('Messages copied to clipboard!', vim.log.levels.INFO)
end, { desc = 'Copy :messages to clipboard' })

-- Shortcut to copy the current file absolute path name to clipboard
vim.keymap.set('n', '<leader>cp', function()
  local path = vim.fn.expand '%:p'
  vim.fn.setreg('+', path)
  vim.notify('Copied absolute path to clipboard: ' .. path, vim.log.levels.INFO)
end, { desc = 'Copy current file absolute [P]ath' })

-- Neovim GUIs (like VimR) where "ghost text" (virtual text used for suggestions, e.g., by `copilot.lua`) does not appear in a distinguishable color. This is usually due to the GUI not supporting or not mapping the `CmpGhostText` or `CopilotSuggestion` highlight groups correctly.
-- [ ] Somehow don't see these styles set by default and had to run manually
vim.api.nvim_set_hl(0, 'CmpGhostText', { fg = '#888888', italic = true })
vim.api.nvim_set_hl(0, 'CopilotSuggestion', { fg = '#888888', italic = true })

-- Set this locally when working with python virtual environment as setting it globally causing other python library errors like taskwiki some libraries not found
-- Activte myenv pyenv before launching nvim for this to work properly
vim.g.python3_host_prog = os.getenv 'HOME' .. '/.pyenv/versions/myenv/bin/python'

-- Load Avante custom keymappings
require 'avante_config'
require 'codecompanion_config'

-- Convert current curl paragraph to .hurl format in-place
-- Prereq: hurlfmt (ships with hurl) must be in PATH
-- Browser dev tools export --data-raw which hurlfmt doesn't accept; sed fixes that first
vim.keymap.set('n', '<leader>ch', [[vip:'<,'>!curl2hurl<CR>]], { desc = 'Convert curl paragraph to [H]url format' })
vim.keymap.set('v', '<leader>ch', [[:'<,'>!curl2hurl<CR>]], { desc = 'Convert curl selection to [H]url format' })
vim.keymap.set('n', '<leader>cH', [[vip:'<,'>!hurl2curl<CR>]], { desc = 'Convert hurl paragraph to curl format' })
vim.keymap.set('v', '<leader>cH', [[:'<,'>!hurl2curl<CR>]], { desc = 'Convert hurl selection to curl format' })
-- Refresh Juniper token — calls juniper_token() from .bash_aliases, writes to ~/patches/juniper/curl/vars.env
vim.keymap.set('n', '<leader>ct', ':!source ~/.bash_aliases && juniper_token<CR>', { desc = 'Refresh Juniper [T]oken' })

-- The line beneath this is called `modeline`. See `:help modeline`

vim.api.nvim_set_hl(0, 'RenderMarkdownInlineHighlight', { fg = '#E39AA6', bg = '#1a190c', bold = true })
vim.o.winbar = "%{expand('%:.')}" -- To show the file path just below tabbar

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'typescriptreact',
  callback = function()
    -- vim.treesitter.query.set(
    --   'tsx',
    --   'injections',
    --   [[
    --    ((comment) @injection.content
    -- 			 (#match? @injection.content "^/\\*\\*")
    --        (#set! injection.language "markdown")
    --        (#set! injection.combined))
    --  ]]
    -- )
    -- Override markdown highlights to ensure they show
    -- vim.api.nvim_set_hl(0, '@markup.strong.markdown_inline', { bold = true, fg = 'Orange' })
    -- vim.api.nvim_set_hl(0, '@markup.strong', { bold = true, fg = 'Orange' })
    -- vim.api.nvim_set_hl(0, '@text.strong', { bold = true, fg = 'Orange' })

    -- Enable markdown highlighting
    -- vim.treesitter.start(0, 'markdown')

    -- Try to enable render-markdown
    -- if package.loaded['render-markdown'] then
    --   require('render-markdown').enable()
    -- end
  end,
})
