-- Undo-tree browsing + a true two-arbitrary-state diff helper.
--
-- atone.nvim gives the best modern browsing UX (graph, persistent marks,
-- word-level inline diff float). It does NOT depend on the nvim-treesitter
-- plugin (uses vim.text.diff / vim.diff + native filetype highlighting), so it
-- is safe on this Neovim 0.12 config where nvim-treesitter was removed.
--
-- No undotree tool diffs two *arbitrary* states natively (each undo seq has a
-- single parent), so `:UndoDiff` below reconstructs both states into scratch
-- buffers and `diffthis`-es them — the same proven pattern used by `<leader>sb`
-- in custom/plugins/telescope.lua.

-- Build a scratch buffer holding the buffer's contents at a given undo `seq`.
-- Temporarily jumps the source buffer to `seq` (no write) to grab its contents,
-- then restores the original seq, so this is safe to call for any seq.
local function snapshot_seq(src_buf, seq, filetype)
  local orig = vim.fn.undotree(src_buf).seq_cur
  vim.api.nvim_buf_call(src_buf, function()
    vim.cmd.undo { seq, mods = { silent = true, emsg_silent = true } }
  end)

  local lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)

  if orig ~= seq then
    vim.api.nvim_buf_call(src_buf, function()
      vim.cmd.undo { orig, mods = { silent = true, emsg_silent = true } }
    end)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  -- Include the buffer id to keep names unique if the same seq is opened twice
  -- (e.g. a scratch snapshot alongside a diff of the same state).
  vim.api.nvim_buf_set_name(buf, ('UNDO:%d (%d)'):format(seq, buf))
  -- `q` closes the whole diff tab in one keypress; both scratch buffers are
  -- bufhidden=wipe, so they get cleaned up automatically.
  vim.keymap.set('n', 'q', '<cmd>tabclose<cr>', { buffer = buf, desc = 'Close UndoDiff' })
  return buf
end

-- Diff two arbitrary undo states of the current buffer side by side.
-- seq_b defaults to the current state.
local function undo_diff(seq_a, seq_b)
  local src_buf = vim.api.nvim_get_current_buf()
  local tree = vim.fn.undotree(src_buf)
  local orig_seq = tree.seq_cur

  seq_b = seq_b or orig_seq
  if seq_a == seq_b then
    vim.notify('UndoDiff: both states are the same (seq ' .. seq_a .. ')', vim.log.levels.WARN)
    return
  end

  local max_seq = tree.seq_last
  for _, s in ipairs { seq_a, seq_b } do
    if s < 0 or s > max_seq then
      vim.notify(('UndoDiff: seq %d out of range (0..%d)'):format(s, max_seq), vim.log.levels.ERROR)
      return
    end
  end

  local filetype = vim.bo[src_buf].filetype

  -- snapshot_seq self-restores the source buffer, so no cleanup needed here.
  local buf_b = snapshot_seq(src_buf, seq_b, filetype)
  local buf_a = snapshot_seq(src_buf, seq_a, filetype)

  vim.cmd 'tabnew'
  vim.api.nvim_set_current_buf(buf_a)
  vim.cmd 'diffthis'
  vim.cmd('leftabove vert sbuffer ' .. buf_b)
  vim.cmd 'diffthis'
end

-- Open a single undo `seq` of `src_buf` in its own scratch tab (no diff).
local function open_scratch(src_buf, seq)
  local buf = snapshot_seq(src_buf, seq, vim.bo[src_buf].filetype)
  vim.cmd 'tabnew'
  vim.api.nvim_set_current_buf(buf)
end

vim.api.nvim_create_user_command('UndoDiff', function(opts)
  local a = tonumber(opts.fargs[1])
  local b = opts.fargs[2] and tonumber(opts.fargs[2]) or nil
  if a == nil then
    vim.notify('Usage: :UndoDiff <seqA> [seqB]', vim.log.levels.ERROR)
    return
  end
  undo_diff(a, b)
end, {
  nargs = '+',
  desc = 'Diff two arbitrary undo states of the current buffer (seqs from :undolist / atone tree)',
})

-- Two-step "anchor and compare" flow: anchor state A, edit/redo around, then
-- diff A against wherever you currently are.
vim.keymap.set('n', '<leader>uda', function()
  vim.b.undo_diff_anchor = vim.fn.undotree().seq_cur
  vim.notify('UndoDiff anchored at seq ' .. vim.b.undo_diff_anchor)
end, { desc = '[U]ndo [D]iff [A]nchor current state' })

vim.keymap.set('n', '<leader>udb', function()
  local anchor = vim.b.undo_diff_anchor
  if anchor == nil then
    vim.notify('No anchor set — use <leader>uda first', vim.log.levels.WARN)
    return
  end
  undo_diff(anchor, vim.fn.undotree().seq_cur)
end, { desc = '[U]ndo [D]iff anchored vs current' })

-- Open the current state in a standalone scratch buffer (no diff). Useful for
-- keeping a snapshot of the buffer as it is now while you continue editing.
vim.keymap.set('n', '<leader>uds', function()
  local src_buf = vim.api.nvim_get_current_buf()
  open_scratch(src_buf, vim.fn.undotree(src_buf).seq_cur)
end, { desc = '[U]ndo current state in [S]cratch buffer' })

-- Inside the atone tree panel, open the node under the cursor in a scratch
-- buffer (no diff). `S` = Scratch; bound buffer-locally to the atone tree.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'atone',
  desc = 'atone: open hovered undo state in a scratch buffer',
  callback = function(ev)
    vim.keymap.set('n', 'S', function()
      local ok, core = pcall(require, 'atone.core')
      local ok2, tree = pcall(require, 'atone.tree')
      local cfg = require('atone.config').opts
      if not (ok and ok2 and core._tree_win and vim.api.nvim_win_is_valid(core._tree_win)) then
        return
      end
      -- Replicate atone's own line -> seq mapping (see atone/core.lua).
      local lnum = vim.api.nvim_win_get_cursor(core._tree_win)[1]
      local id = cfg.ui.compact and tree.total - lnum + 1 or tree.total - (lnum - 1) / 2
      if id % 1 ~= 0 then
        vim.notify('Atone: cursor is between nodes — move onto a node', vim.log.levels.WARN)
        return
      end
      open_scratch(core.attach_buf, tree.id_2seq(id))
    end, { buffer = ev.buf, desc = 'Open hovered undo state in scratch buffer' })
  end,
})

return {
  {
    'XXiaoA/atone.nvim',
    cmd = 'Atone',
    keys = {
      { '<leader>uu', '<cmd>Atone<cr>', desc = '[U]ndotree (atone)' },
    },
    opts = {},
  },
}
