return {
  { -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    main = 'nvim-treesitter.configs',
    dependencies = {
      { 'nvim-treesitter/nvim-treesitter-textobjects' },
      {
        'nvim-treesitter/nvim-treesitter-context',
        opts = {
          enable = true,
          mode = 'topline',
          line_numbers = false,
          multiwindow = false,
          max_lines = 5,
          multiline_threshold = 20,
        },
        config = function(_, opts)
          require('treesitter-context').setup(opts)
          local function set_context_lines(lines)
            lines = tonumber(lines)
            if lines and lines >= 0 then
              opts.max_lines = lines
              require('treesitter-context').setup(opts)
              vim.notify('treesitter-context max_lines set to ' .. lines)
            else
              vim.notify('Invalid input for max_lines', vim.log.levels.ERROR)
            end
          end
          vim.api.nvim_create_user_command('SetContextLines', function(args)
            set_context_lines(args.fargs[1])
          end, { nargs = 1, desc = 'Set nvim-treesitter-context max_lines' })
        end,
      },
    },
    opts = {
      ensure_installed = { 'bash', 'c', 'diff', 'html', 'hurl', 'json', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
      auto_install = false,
      highlight = {
        enable = true,
        disable = function(_, buf)
          -- Check the 'large_buf' variable set on the buffer
          return vim.b[buf].large_buf == true
        end,
        additional_vim_regex_highlighting = { 'ruby' },
      },
      indent = { enable = true, disable = { 'ruby' } },
      textobjects = {
        swap = {
          enable = true,
          swap_next = {
            ['<leader>ta'] = '[t]reesitter @parameter.inner',
          },
          swap_previous = {
            ['<leader>tA'] = '[t]reesitter @parameter.inner',
          },
        },
      },
    },
  },
}
