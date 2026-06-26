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

-- [ ] Seeing LSP errors while editing file may be some LSP events are registered even before disabling it
-- autocmd('BufReadPre', {
--   desc = 'Configure buffer settings based on file size and content',
--   callback = function(ctx)
--     local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
--     local ok, stats = pcall(vim.loop.fs_stat, bufname)
--
--     -- Early return for non-existent files (like temporary buffers)
--     if not ok or not stats then
--       return
--     end
--
--     local has_long_lines = false
--     -- Safely check for long lines only if file exists and is readable
--     local ok_read, lines = pcall(io.open, bufname, 'r')
--     if ok_read and lines then
--       local function check_lines()
--         for line in lines:lines() do
--           if #line > 500 then
--             return true
--           end
--         end
--         return false
--       end
--
--       has_long_lines = check_lines()
--       lines:close()
--     end
--
--     -- 500Kb (if want it to be enabled, can trigger "syntax on" manually)
--     if (stats.size > 5000000) or has_long_lines then
--       vim.b.large_buf = true
--       vim.b.lsp_disable = true
--       vim.cmd 'syntax off'
--       vim.opt_local.foldmethod = 'manual'
--       vim.opt_local.spell = false
--     else
--       vim.b.large_buf = false
--     end
--   end,
-- })
