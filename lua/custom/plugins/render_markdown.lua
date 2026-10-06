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
          -- Disable the cursor-line "show raw" behavior in every rendered mode
          -- except insert. Result: normal/command/terminal stay fully rendered
          -- (easy to browse); in insert mode only the current line shows raw
          -- markdown so you can edit it in place. This replaces the old
          -- per-element `ignore = { ... = { 'n' } }` list, which missed inline
          -- emphasis markers and so leaked raw markdown on the cursor line.
          disabled_modes = { 'n', 'c', 't' },
        },
        -- Native-conceal elements (table pipes, inline-code backticks, `**`/`_`
        -- markers, link URLs) are hidden via Neovim's own `conceal`, which is
        -- governed by `concealcursor`, NOT by anti_conceal above. The plugin's
        -- default reveals them on the cursor line in *all* modes (rendered = '').
        -- Set 'nc' so they stay hidden (rendered) on the cursor line in normal
        -- and command mode, and are only revealed (raw) while in insert mode —
        -- completing the hybrid behavior for these elements.
        win_options = {
          concealcursor = { rendered = 'nc' },
        },
        html = { enabled = false },
        -- Tables are formatted with prettier, so the source already carries column
        -- padding. The default 'padded' counts that whitespace when sizing columns
        -- and widens the render further; 'trimmed' subtracts it.
        pipe_table = {
          cell = 'trimmed',
          -- Fit wide tables to the current window by wrapping individual cells.
          wrap = true,
        },
        -- Priority tasks: `- [!]` high, `- [ ]` normal, `- [~]` low. These are custom
        -- states, not GFM, so a finished task of any priority goes to `[x]`.
        -- scope_highlight colours the task text too, not just the icon. `[-]` is left
        -- to the plugin's built-in `todo` (in-progress) state.
        checkbox = {
          custom = {
            high = { raw = '[!]', rendered = '\u{f0026} ', highlight = 'DiagnosticError', scope_highlight = 'DiagnosticError' },
            low = { raw = '[~]', rendered = '\u{f0045} ', highlight = 'Comment', scope_highlight = 'Comment' },
          },
        },
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

      -- Keep wrapped table rows rendered under the cursor outside insert mode.
      require('render_markdown_cursor_row').setup()

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

      -- Convert a box-drawn table (┌─┬─┐ │ … │, as printed by Claude Code and other CLIs) into a
      -- markdown pipe table, which render-markdown can then render and wrap to the window.
      -- Rows split across several `│` lines are joined back into one cell per column; the
      -- ┌├└ border lines mark where one row ends and the next begins.
      vim.api.nvim_create_user_command('BoxTableToMarkdown', function(opts)
        local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
        local rows, cur = {}, nil
        local function flush()
          if cur then
            rows[#rows + 1] = vim.tbl_map(function(parts)
              return (table.concat(parts, ' '):gsub('|', '\\|'))
            end, cur)
            cur = nil
          end
        end
        for _, line in ipairs(lines) do
          local body = vim.trim(line)
          if vim.startswith(body, '│') then
            local cells = vim.split(body, '│', { plain = true })
            -- drop the empty strings before the first and after the last bar
            cells = vim.list_slice(cells, 2, #cells - 1)
            cur = cur or vim.tbl_map(function()
              return {}
            end, cells)
            for i, cell in ipairs(cells) do
              cell = vim.trim(cell)
              if cell ~= '' and cur[i] then
                table.insert(cur[i], cell)
              end
            end
          else
            flush()
          end
        end
        flush()
        if #rows == 0 then
          vim.notify('BoxTableToMarkdown: no │ rows in range', vim.log.levels.WARN)
          return
        end
        local out = { '| ' .. table.concat(rows[1], ' | ') .. ' |', '|' .. string.rep('---|', #rows[1]) }
        for i = 2, #rows do
          out[#out + 1] = '| ' .. table.concat(rows[i], ' | ') .. ' |'
        end
        vim.api.nvim_buf_set_lines(0, opts.line1 - 1, opts.line2, false, out)
      end, { range = '%', desc = 'Convert a box-drawn table to a markdown pipe table' })

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
