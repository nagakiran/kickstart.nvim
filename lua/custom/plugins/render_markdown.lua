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
      require('render-markdown').setup {
        anti_conceal = {
          enabled = true,
          ignore = {
            head_icon = { 'n' },
            head_background = { 'n' },
            head_border = { 'n' },
            code_language = { 'n' },
            code_background = { 'n' },
            code_border = { 'n' },
            dash = { 'n' },
            bullet = { 'n' },
            check_icon = { 'n' },
            check_scope = { 'n' },
            quote = { 'n' },
            table_border = { 'n' },
            callout = { 'n' },
            link = { 'n' },
            sign = { 'n' },
          },
        },
        html = { enabled = false },
        render_modes = { 'n', 'c', 't', 'i' },
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

      -- Custom command to toggle anti_conceal dynamically at runtime
      vim.api.nvim_create_user_command('RenderMarkdownToggleAntiConceal', function()
        local config = require('render-markdown.state').config
        local new_state = not config.anti_conceal.enabled
        require('render-markdown').setup { anti_conceal = { enabled = new_state } }
        vim.notify('Markdown Anti-Conceal: ' .. (new_state and 'Enabled' or 'Disabled'))
      end, { desc = 'Toggle Render-Markdown Anti-Conceal' })
    end,
  },
}
