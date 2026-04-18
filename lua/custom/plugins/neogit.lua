return {
  'NeogitOrg/neogit',
  lazy = true,
  dependencies = {
    'nvim-lua/plenary.nvim', -- required

    -- Only one of these is needed.
    'sindrets/diffview.nvim', -- optional
    'esmuellert/codediff.nvim', -- optional

    -- For a custom log pager
    'm00qek/baleia.nvim', -- optional

    -- Only one of these is needed.
    'nvim-telescope/telescope.nvim', -- optional
    'ibhagwan/fzf-lua', -- optional
    'nvim-mini/mini.pick', -- optional
    'folke/snacks.nvim', -- optional
  },
  cmd = 'Neogit',
  keys = {
    { '<leader>gg', '<cmd>Neogit<cr>', desc = 'Show Neogit UI' },
  },
  config = function()
    require('neogit').setup {}

    -- Fix neogit diff highlights for gruvbox colorscheme.
    -- Gruvbox's diff colors cause poor contrast in neogit's inline diff view.
    local function set_neogit_gruvbox_highlights()
      -- Context (unchanged lines in diff)
      vim.api.nvim_set_hl(0, 'NeogitDiffContext', { bg = '#282828', fg = '#ebdbb2' })
      vim.api.nvim_set_hl(0, 'NeogitDiffContextHighlight', { bg = '#32302f', fg = '#ebdbb2' })

      -- Added lines: gruvbox bright green on dark green bg
      vim.api.nvim_set_hl(0, 'NeogitDiffAdd', { bg = '#1d2b1d', fg = '#b8bb26' })
      vim.api.nvim_set_hl(0, 'NeogitDiffAddHighlight', { bg = '#2a3a1d', fg = '#b8bb26' })

      -- Deleted lines: gruvbox bright red on dark red bg
      vim.api.nvim_set_hl(0, 'NeogitDiffDelete', { bg = '#2b1b1b', fg = '#fb4934' })
      vim.api.nvim_set_hl(0, 'NeogitDiffDeleteHighlight', { bg = '#3a1d1d', fg = '#fb4934' })

      -- Hunk header (@@ ... @@)
      vim.api.nvim_set_hl(0, 'NeogitHunkHeader', { bg = '#3c3836', fg = '#83a598', bold = true })
      vim.api.nvim_set_hl(0, 'NeogitHunkHeaderHighlight', { bg = '#504945', fg = '#83a598', bold = true })
    end

    set_neogit_gruvbox_highlights()

    -- Re-apply after any colorscheme change (e.g. :colorscheme gruvbox reload)
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('NeogitGruvboxFix', { clear = true }),
      callback = set_neogit_gruvbox_highlights,
    })
  end,
}
