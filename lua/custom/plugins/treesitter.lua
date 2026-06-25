return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    build = ':TSUpdate',
    main = 'nvim-treesitter',
    dependencies = {
      { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'main' },
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
          end, { nargs = 1, desc = 'Set treesitter-context max_lines' })
        end,
      },
    },
    init = function()
      vim.api.nvim_create_autocmd('FileType', {
        callback = function(args)
          if vim.b[args.buf].large_buf then
            return
          end
          pcall(vim.treesitter.start, args.buf)
          vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end,
      })
    end,
  },
}
