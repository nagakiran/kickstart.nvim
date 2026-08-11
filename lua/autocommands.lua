local bigbuf = require 'bigbuf'

-- Create an autocommand group for LSP-related commands
local lsp_group = vim.api.nvim_create_augroup('CustomLSP', { clear = true })

-- Autocommand to disable LSP for large buffers and special filetypes
vim.api.nvim_create_autocmd('LspAttach', {
  group = lsp_group,
  callback = function(args)
    local buffer = args.buf
    local client_id = args.data.client_id
    -- Check if large_buf is set for this buffer
    if vim.b[buffer].large_buf then
      vim.lsp.buf_detach_client(buffer, client_id)
      vim.notify(string.format('LSP disabled for large buffer: %s', vim.fn.bufname(buffer)), vim.log.levels.INFO)
    end
    -- Detach non-Copilot LSP clients from taskwarrior edit buffers; willSaveWaitUntil
    -- rewrites the buffer before disk write and strips user-added annotations
    if vim.bo[buffer].filetype == 'taskedit' then
      local client = vim.lsp.get_client_by_id(client_id)
      if client and client.name ~= 'copilot' then
        vim.lsp.buf_detach_client(buffer, client_id)
      end
    end
  end,
})
-- Create an autocommand group
local augroup = vim.api.nvim_create_augroup('CustomAutocommands', { clear = true })

-- Helper function to create autocommands
local function autocmd(event, opts)
  opts.group = augroup
  return vim.api.nvim_create_autocmd(event, opts)
end
-- Useful when symlinked location is not part of gitrepo
vim.api.nvim_create_user_command('FollowSymLink', function()
  local resolved_path = vim.fn.resolve(vim.fn.expand '%')
  vim.cmd('file ' .. resolved_path)
  vim.cmd 'edit'
end, {})

-- Taskwarrior edit files require annotation continuation lines indented to exactly 21
-- spaces. nvim-treesitter's indentexpr + noexpandtab inserts tabs instead, which
-- taskwarrior cannot parse, so annotations are silently dropped. Force space-based,
-- treesitter-free indentation for these buffers.
autocmd('FileType', {
  pattern = 'taskedit',
  callback = function()
    vim.opt_local.expandtab = true -- spaces, never tabs
    vim.opt_local.indentexpr = '' -- disable nvim-treesitter indentexpr
    vim.opt_local.autoindent = false -- start new lines clean; user spaces to col 21
    vim.opt_local.softtabstop = 0
  end,
})

-- Bypass LSP willSaveWaitUntil for taskwarrior edit files by taking over the write directly.
-- willSaveWaitUntil fires as part of Neovim's normal write path and rewrites the buffer,
-- stripping user-added annotations. BufWriteCmd skips that path entirely.
autocmd('BufWriteCmd', {
  pattern = '*.task',
  callback = function(args)
    vim.fn.writefile(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false), args.file)
    vim.bo[args.buf].modified = false
  end,
})

-- Mark oversized buffers. Note this is *not* `large_buf`: that one means "never start
-- tree-sitter at all" (see lua/custom/plugins/treesitter.lua). Heavy buffers keep their
-- tree-sitter highlighting and markdown rendering for browsing; only insert mode is stripped
-- down, by the pair of autocommands below.
autocmd('BufReadPre', {
  desc = 'Flag buffers too big to re-parse on every keystroke',
  callback = function(ctx)
    vim.b[ctx.buf].heavy_buf = bigbuf.is_heavy(ctx.buf)
  end,
})

-- Suspending and restoring both cost a full re-parse (~380ms on a 1.7MB file), so a
-- type/<Esc>/type rhythm would pay it on every <Esc>. Hold the restore back briefly and cancel
-- it if insert mode is re-entered first.
local RESTORE_DELAY_MS = 150
local restore_timers = {}

local function cancel_restore(buf)
  local timer = restore_timers[buf]
  if timer then
    timer:stop()
    timer:close()
    restore_timers[buf] = nil
  end
end

-- Everything that re-parses the buffer as you type: the tree-sitter highlighter, the
-- render-markdown decorator (its update runs a *synchronous* parse of the visible range), and
-- nvim-treesitter's indentexpr (a synchronous parse on every <CR>/o/=).
local function suspend(buf)
  if vim.b[buf].render_suspended then
    return
  end
  vim.b[buf].render_suspended = true
  vim.b[buf].saved_indentexpr = vim.bo[buf].indentexpr
  vim.bo[buf].indentexpr = ''
  pcall(vim.cmd, 'RenderMarkdown buf_disable')

  -- Only touch highlighting if tree-sitter is what is doing it. A heavy buffer whose filetype
  -- has no parser is highlighted by regex syntax, which is viewport-local and cheap -- leave
  -- it alone rather than blanking something we cannot put back.
  local had_ts = vim.treesitter.highlighter.active[buf] ~= nil
  vim.b[buf].saved_ts = had_ts
  if had_ts then
    -- Stopping the highlighter fires the `syntaxset` FileType autocmd, which switches regex
    -- syntax on; restoring the previous value keeps the buffer from recolouring itself on
    -- every InsertEnter.
    local saved_syntax = vim.bo[buf].syntax
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].syntax = saved_syntax
  end
end

local function restore(buf)
  if not vim.b[buf].render_suspended then
    return
  end
  vim.b[buf].render_suspended = false
  vim.bo[buf].indentexpr = vim.b[buf].saved_indentexpr or ''
  if vim.b[buf].saved_ts then
    pcall(vim.treesitter.start, buf)
  end
  pcall(vim.cmd, 'RenderMarkdown buf_enable')
end

autocmd('InsertEnter', {
  desc = 'Stop re-parsing heavy buffers while typing',
  callback = function(ctx)
    if not vim.b[ctx.buf].heavy_buf then
      return
    end
    cancel_restore(ctx.buf)
    suspend(ctx.buf)
  end,
})

autocmd('InsertLeave', {
  desc = 'Restore highlighting and markdown rendering after typing',
  callback = function(ctx)
    local buf = ctx.buf
    if not vim.b[buf].render_suspended then
      return
    end
    cancel_restore(buf)
    local timer = vim.uv.new_timer()
    restore_timers[buf] = timer
    timer:start(
      RESTORE_DELAY_MS,
      0,
      vim.schedule_wrap(function()
        cancel_restore(buf)
        if vim.api.nvim_buf_is_valid(buf) then
          restore(buf)
        end
      end)
    )
  end,
})

autocmd('BufDelete', {
  callback = function(ctx)
    cancel_restore(ctx.buf)
  end,
})

vim.api.nvim_create_user_command('HeavyBufToggle', function()
  local buf = vim.api.nvim_get_current_buf()
  local heavy = not vim.b[buf].heavy_buf
  vim.b[buf].heavy_buf = heavy
  if not heavy then
    cancel_restore(buf)
    restore(buf)
  end
  vim.notify(string.format('%s: heavy buffer %s', vim.fn.bufname(buf), heavy and 'ON (raw text while typing)' or 'OFF (always rendered)'))
end, { desc = 'Toggle deferred rendering for the current buffer' })
