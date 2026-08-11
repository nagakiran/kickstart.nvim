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

--- Byte size of the file backing `buf`, or 0 when it has none (scratch, terminal, unwritten).
---@param buf integer
---@return integer
function M.size(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return 0
  end
  local stat = vim.uv.fs_stat(name)
  return stat and stat.size or 0
end

---@param buf integer
---@return boolean
function M.is_heavy(buf)
  return M.size(buf) > M.threshold
end

return M
