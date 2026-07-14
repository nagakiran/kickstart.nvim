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
    ft = { 'markdown', 'Avante', 'codecompanion', 'typescriptreact', 'gitcommit' },
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
        file_types = { 'markdown', 'typescriptreact', 'Avante', 'codecompanion', 'gitcommit' },
        injections = {
          typescriptreact = {
            enabled = true,
            query = [[
									((comment) @injection.content
                    (#set! injection.language "markdown"))
								]],
          },
          -- Render markdown in the commit message body when writing a commit
          -- (filetype `gitcommit`). `message_line` nodes are the body lines;
          -- `injection.combined` joins them into one markdown document so
          -- multi-line constructs (code fences, lists) render, while the
          -- `# ...` comment lines (separate `comment` nodes) stay untouched.
          gitcommit = {
            enabled = true,
            query = [[
              ((message_line) @injection.content
                (#set! injection.combined)
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

      -- Copy markdown to the clipboard as rich text, so it can be pasted into Outlook,
      -- Confluence or Teams with formatting intact. What render-markdown draws is virtual
      -- text and cannot be yanked, so the markdown *source* is what gets converted.
      -- The script puts RTF (for native apps) and HTML (for web/Electron apps) on the
      -- pasteboard at once, plus the raw markdown as the plain-text flavor.
      local rich_text_script = vim.fs.joinpath(vim.fn.stdpath 'config', 'scripts', 'md-to-rich-clipboard.sh')

      vim.api.nvim_create_user_command('CopyRichText', function(opts)
        local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
        local tmp = vim.fn.tempname() .. '.md'
        vim.fn.writefile(lines, tmp)
        vim.system({ rich_text_script, tmp }, { text = true }, function(result)
          vim.schedule(function()
            os.remove(tmp)
            if result.code == 0 then
              vim.notify(('Copied %d line%s as rich text'):format(#lines, #lines == 1 and '' or 's'))
            else
              local err = (result.stderr ~= nil and result.stderr ~= '') and result.stderr or ('exited with ' .. result.code)
              vim.notify('CopyRichText failed: ' .. err, vim.log.levels.ERROR)
            end
          end)
        end)
      end, { range = '%', desc = 'Copy markdown as rich text (Outlook/Confluence/Teams)' })

      local rich_text_filetypes = { 'markdown', 'codecompanion', 'Avante', 'gitcommit' }

      local function map_rich_text(buf)
        vim.keymap.set('n', '<leader>cf', '<Cmd>CopyRichText<CR>', { buffer = buf, desc = 'Copy [F]ile as rich text' })
        -- `:` rather than `<Cmd>` so Vim prefills the '<,'> range from the selection
        vim.keymap.set('x', '<leader>cx', ':CopyRichText<CR>', { buffer = buf, desc = 'Copy selection as rich text' })
      end

      vim.api.nvim_create_autocmd('FileType', {
        pattern = rich_text_filetypes,
        callback = function(args)
          map_rich_text(args.buf)
        end,
      })

      -- This plugin lazy-loads on the filetypes above, so FileType has already fired for the
      -- buffer that triggered the load; the autocmd alone would miss that first buffer.
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.tbl_contains(rich_text_filetypes, vim.bo[buf].filetype) then
          map_rich_text(buf)
        end
      end
    end,
  },
}
