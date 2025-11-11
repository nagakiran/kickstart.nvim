return {
  {
    -- Make sure to set this up properly if you have lazy=true
    'MeanderingProgrammer/render-markdown.nvim',
    -- opts = {
    --   file_types = { 'markdown', 'Avante', 'codecompanion', 'typescriptreact' },
    --   -- Out of the box language injections for known filetypes that allow markdown to be
    --   -- interpreted in specified locations, see :h treesitter-language-injections
    --   -- Set enabled to false in order to disable
    --   injections = {
    --     typescriptreact = {
    --       enabled = true,
    --       query = [[
    --         ((message) @injection.content
    --             (#set! injection.combined)
    --             (#set! injection.include-children)
    --             (#set! injection.language "markdown"))
    --     ]],
    --     },
    --   },
    --   regions = {
    --     typescriptreact = {
    --       -- Render markdown inside /* md ... */ comments
    --       { start = '/%*%s*md', finish = '%*/' },
    --       -- Optionally, render inside JSX <Markdown>...</Markdown> blocks
    --       { start = '<Markdown>', finish = '</Markdown>' },
    --     },
    --   },
    -- },
    ft = { 'markdown', 'Avante', 'codecompanion', 'typescriptreact' },
    config = function()
      -- vim.treesitter.language.register('markdown', 'typescriptreact')
      require('render-markdown').setup {
        file_types = { 'markdown', 'typescriptreact', 'Avante', 'codecompanion' },
        injections = {
          typescriptreact = {
            enabled = true,
            query = [[
									((comment) @injection.content
                    (#set! injection.language "markdown"))
								]],
          },
        },
        overrides = {
          filetype = {
            -- codecompanion = {
            --   bullet = { enabled = false },
            -- },
          },
        },
      }
    end,
  },
}
