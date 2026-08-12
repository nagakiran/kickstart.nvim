local bigbuf = require 'bigbuf'
local mdsyntax = require 'mdsyntax'

-- Create an autocommand group for LSP-related commands
local lsp_group = vim.api.nvim_create_augroup('CustomLSP', { clear = true })

-- Autocommand to detach LSP clients from special filetypes
vim.api.nvim_create_autocmd('LspAttach', {
  group = lsp_group,
  callback = function(args)
    local buffer = args.buf
    local client_id = args.data.client_id
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

-- Mark oversized buffers. Heavy buffers keep their tree-sitter highlighting and markdown
-- rendering for browsing; only insert mode is stripped down, by the autocommands below.
autocmd('BufReadPre', {
  desc = 'Flag buffers too big to re-parse on every keystroke',
  callback = function(ctx)
    vim.b[ctx.buf].heavy_buf = bigbuf.is_heavy(ctx.buf)
  end,
})

-- `after/syntax/markdown.vim` has to be layered on top of tree-sitter, i.e. *after*
-- nvim-treesitter's own FileType handler has blanked 'syntax' (which fires `Syntax` -> `syn
-- clear`). This module is required before `lazy.setup()`, so scheduling is what puts us last
-- rather than depending on registration order.
autocmd('FileType', {
  pattern = 'markdown',
  desc = 'Layer custom regex syntax on top of tree-sitter highlighting',
  callback = function(ctx)
    vim.schedule(function()
      mdsyntax.apply(ctx.buf)
    end)
  end,
})

-- Suspending and restoring both cost a full re-parse (~380ms on a 1.7MB file), so a
-- type/<Esc>/type rhythm would pay it on every <Esc>. Hold the restore back briefly and cancel
-- it if insert mode is re-entered first.
local RESTORE_DELAY_MS = 150

-- Buffers currently stripped down, tracked here rather than read back out of `vim.b` so a restore
-- never depends on being handed the right buffer by an autocmd. (`vim.b.render_suspended` is kept
-- as the user-visible flag.)
local suspended = {}

-- A single timer, cancelled by bumping `generation`: `timer:stop()` cannot un-queue a tick that
-- `schedule_wrap` has already handed to the main loop, so the callback has to check whether it is
-- still the current one.
local restore_timer = vim.uv.new_timer()
local generation = 0

local function cancel_restore()
  generation = generation + 1
  restore_timer:stop()
end

-- `:RenderMarkdown buf_enable`/`buf_disable` act on the *current* buffer (manager.set_buf(nil, ...)),
-- not on any buffer we name, so bind the target explicitly.
local function render_markdown_set(buf, enable)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd('RenderMarkdown ' .. (enable and 'buf_enable' or 'buf_disable'))
  end)
end

-- Everything that re-parses the buffer as you type: the tree-sitter highlighter, the
-- render-markdown decorator (its update runs a *synchronous* parse of the visible range), and
-- nvim-treesitter's indentexpr (a synchronous parse on every <CR>/o/=).
local function suspend(buf)
  if suspended[buf] then
    return
  end
  suspended[buf] = true
  vim.b[buf].render_suspended = true
  vim.b[buf].saved_indentexpr = vim.bo[buf].indentexpr
  vim.bo[buf].indentexpr = ''
  render_markdown_set(buf, false)

  -- Only touch highlighting if tree-sitter is what is doing it. A heavy buffer whose filetype
  -- has no parser is highlighted by regex syntax, which is viewport-local and cheap -- leave
  -- it alone rather than blanking something we cannot put back.
  local had_ts = vim.treesitter.highlighter.active[buf] ~= nil
  vim.b[buf].saved_ts = had_ts
  if had_ts then
    -- Stopping the highlighter fires the `syntaxset` FileType autocmd, which switches full regex
    -- syntax on -- expensive on a file this size. Blank it again, then put back just our own
    -- rules: the assignment triggers `syn clear`, which would otherwise drop them for good.
    local saved_syntax = vim.bo[buf].syntax
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].syntax = saved_syntax
    mdsyntax.apply(buf)
  end
end

local function restore(buf)
  if not suspended[buf] then
    return
  end
  suspended[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.b[buf].render_suspended = false
  vim.bo[buf].indentexpr = vim.b[buf].saved_indentexpr or ''
  if vim.b[buf].saved_ts then
    pcall(vim.treesitter.start, buf)
    -- `vim.treesitter.start` blanks 'syntax' again, so our rules need re-applying here too.
    mdsyntax.apply(buf)
  end
  render_markdown_set(buf, true)
end

-- Restore every suspended buffer except the one being typed in. Sweeping rather than restoring a
-- single buffer is what makes leaving insert mode somewhere else (a window switch, a plugin float)
-- still hand the heavy buffer back.
local function restore_all()
  -- `ni*` is insert-normal (`<C-o>`, i.e. the `<C-s>` save mapping): still mid-edit, so restoring
  -- there would pay a full re-parse only to suspend again a moment later.
  local mode = vim.api.nvim_get_mode().mode
  local typing = mode:find '^i' or mode:find '^ni'
  local typing_in = typing and vim.api.nvim_get_current_buf() or nil
  for buf in pairs(suspended) do
    if buf ~= typing_in then
      restore(buf)
    end
  end
end

local function schedule_restore(delay)
  if next(suspended) == nil then
    return
  end
  cancel_restore()
  local mine = generation
  restore_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if mine == generation then
        restore_all()
      end
    end)
  )
end

autocmd('InsertEnter', {
  desc = 'Stop re-parsing heavy buffers while typing',
  callback = function(ctx)
    if not vim.b[ctx.buf].heavy_buf then
      return
    end
    cancel_restore()
    suspend(ctx.buf)
  end,
})

-- ModeChanged rather than InsertLeave: `<C-c>` leaves insert mode without firing InsertLeave, which
-- used to strand the buffer with no highlighting and no rendering until it was reloaded.
autocmd('ModeChanged', {
  pattern = 'i*:*',
  desc = 'Restore highlighting and markdown rendering after typing',
  callback = function()
    schedule_restore(RESTORE_DELAY_MS)
  end,
})

-- Self-heal: whatever path stranded a buffer, entering it or going idle outside insert mode brings
-- it back.
autocmd({ 'BufEnter', 'CursorHold' }, {
  callback = function()
    schedule_restore(RESTORE_DELAY_MS)
  end,
})

autocmd('BufDelete', {
  callback = function(ctx)
    suspended[ctx.buf] = nil
  end,
})

autocmd('VimLeavePre', {
  callback = function()
    restore_timer:stop()
    if not restore_timer:is_closing() then
      restore_timer:close()
    end
  end,
})

vim.api.nvim_create_user_command('HeavyBufToggle', function()
  local buf = vim.api.nvim_get_current_buf()
  local heavy = not vim.b[buf].heavy_buf
  vim.b[buf].heavy_buf = heavy
  if not heavy then
    cancel_restore()
    restore(buf)
  end
  vim.notify(string.format('%s: heavy buffer %s', vim.fn.bufname(buf), heavy and 'ON (raw text while typing)' or 'OFF (always rendered)'))
end, { desc = 'Toggle deferred rendering for the current buffer' })
