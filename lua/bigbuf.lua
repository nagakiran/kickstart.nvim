-- Shared "heavy buffer" policy.
--
-- tree-sitter's markdown grammar re-parses essentially the whole document on every edit -- its
-- block-level parser is not meaningfully incremental -- so parse cost grows linearly with file
-- size: ~8ms/keystroke at 60KB, ~46ms at 400KB, ~233ms at 1.7MB (nvim 0.12.3). Past the
-- threshold that is enough to make typing visibly lag.
--
-- Buffers over `threshold` are marked heavy (`vim.b.heavy_buf`, set in `autocommands.lua`) and
-- are kept out of the per-keystroke consumers: tree-sitter/render-markdown while in insert
-- mode, cmp's buffer word index, copilot, and gitsigns.
local M = {}

M.threshold = 400 * 1024

--- Byte size of `buf`: the file backing it when there is one, otherwise the text it holds.
---
--- The in-memory fallback is what makes this correct for scratch buffers. Picker previewers fill a
--- `nofile` buffer with a whole file and either leave it unnamed or name it something synthetic
--- (fzf-lua uses `<bufnr>/<path>`, which never exists on disk), so a name-based `fs_stat` reports 0
--- for exactly the buffers carrying the most text -- and every consumer of `is_heavy` then treated
--- a 56,000-line ledger preview as a small buffer. cmp-buffer indexed 35 such copies at once.
---@param buf integer
---@return integer
function M.size(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local stat = name ~= '' and vim.uv.fs_stat(name) or nil
  if stat then
    return stat.size
  end
  -- `nvim_buf_get_offset` returns -1 for an unloaded buffer.
  local ok, bytes = pcall(vim.api.nvim_buf_get_offset, buf, vim.api.nvim_buf_line_count(buf))
  return (ok and bytes > 0) and bytes or 0
end

---@param buf integer
---@return boolean
function M.is_heavy(buf)
  return M.size(buf) > M.threshold
end

return M
