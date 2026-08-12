-- Regex syntax rules layered on top of tree-sitter highlighting (`after/syntax/markdown.vim`:
-- `@word`, `@# comment`, underlined URLs).
--
-- Tree-sitter attach blanks 'syntax', and *every* assignment to 'syntax' fires the `Syntax` event,
-- whose handler `s:SynSet()` (runtime/syntax/synload.vim) starts with an unconditional `syn clear`.
-- `vim.treesitter.start()` does not re-source anything, so these rules have to be re-applied by
-- hand every time highlighting is torn down and brought back -- see `suspend`/`restore` in
-- `lua/autocommands.lua`.
local M = {}

M.file = vim.fn.stdpath 'config' .. '/after/syntax/markdown.vim'

--- Re-apply the custom syntax rules to `buf` (defaults to the current buffer).
---@param buf? integer
function M.apply(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'markdown' then
    return
  end
  -- `syn match` applies to whatever buffer is current, hence nvim_buf_call.
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd.source(M.file)
  end)
end

return M
