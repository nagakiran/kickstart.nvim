-- Create an autocommand group for LSP-related commands
local lsp_group = vim.api.nvim_create_augroup('CustomLSP', { clear = true })

-- Autocommand to disable LSP for large buffers
vim.api.nvim_create_autocmd('LspAttach', {
  group = lsp_group,
  callback = function(args)
    local buffer = args.buf
    -- Check if large_buf is set for this buffer
    if vim.b[buffer].large_buf then
      -- Get the client ID that just attached
      local client_id = args.data.client_id
      -- Detach the LSP client from this buffer
      vim.lsp.buf_detach_client(buffer, client_id)

      -- Optional: Show a notification that LSP was disabled
      vim.notify(string.format('LSP disabled for large buffer: %s', vim.fn.bufname(buffer)), vim.log.levels.INFO)
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
