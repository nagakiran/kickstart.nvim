-- Reaper for orphaned picker preview buffers.
--
-- Telescope and fzf-lua both build a scratch buffer per previewed entry, fill it with the whole
-- file, and start tree-sitter on it. Neither reliably deletes them:
--
--   * telescope's `new_buffer_previewer` deletes `old_bufs` in its teardown, but buffers stranded
--     by an abnormal close (or held as the last previewed buffer) survive as unnamed `nofile`
--     buffers with a live highlighter;
--   * fzf-lua keeps them deliberately -- `previewer/bcache.lua:M:set()` does
--     `vim.bo[buf].bufhidden = "hide"` with the comment "remove buffer auto-delete since it's now
--     cached" -- and only `Previewer.base:close()` clears that cache, which does not run on every
--     teardown path.
--
-- The cost is not the text. Measured on ten hidden copies of a 1.37MB ledger file: +2.1MB each as
-- plain buffers, +61.2MB each once tree-sitter parses them -- roughly 45x the file size. A session
-- that had accumulated 241 such buffers (90MB of text) was holding 2.29GB of MALLOC_SMALL and a
-- 5.4GB footprint. Deleting the buffer is what releases the parse tree; it also takes the extmarks,
-- the buffer-local autocmds (colorizer/render-markdown attach per buffer) and cmp-buffer's word
-- index with it, so this one sweep covers every downstream consumer at once.
local M = {}

-- Buffers that are legitimately `nofile`+`hide` and hold state the user came back for. Chat
-- scrollback and query results are worth keeping: measured together they were 0.5MB, i.e. noise
-- next to the 90MB of preview leftovers.
local KEEP_FT = {
  codecompanion = true,
  dbui = true,
  dbout = true,
  dbout_preview = true,
  cmp_menu = true,
  cmp_docs = true,
  TelescopePrompt = true,
  TelescopeResults = true,
  fzf = true,
  noice = true,
  notify = true,
  qf = true,
  help = true,
  man = true,
}

M.idle_ms = 120 * 1000
M.sweep_ms = 60 * 1000

-- Real file buffers are unloaded rather than deleted, and on a much longer fuse: unloading is
-- cheap to undo (the next `:b` rereads from disk) but it does drop the cursor/fold state that a
-- buffer you are cycling through would want to keep.
M.unload_ms = 30 * 60 * 1000

-- nvim-treesitter-context re-renders its marks on every update but never clears the old ones from
-- its own scratch buffer; one session had 2066 marks on a 3-line buffer. Clearing the namespace is
-- safe -- the next update repaints it.
local CONTEXT_MARK_RATIO = 10

--- Buffers displayed anywhere, including on other tabpages. `bufwinid()` only sees the current
--- tabpage, which is the same trap already worked around in `custom/plugins/fzf.lua`.
---@return table<integer, true>
local function displayed()
  local out = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      out[vim.api.nvim_win_get_buf(win)] = true
    end
  end
  return out
end

--- Buffers a live fzf-lua previewer still owns, or nil when they cannot be enumerated.
---
--- Reaping one of these would corrupt the picker rather than merely cost it a redraw:
--- `populate_preview_buf` does `local buf = (cached or {}).bufnr or self:get_tmp_buffer()` and
--- `_apply_cached_preview` reuses a cached bufnr outright -- neither revalidates the handle.
---
--- Enumerating them (rather than skipping the whole sweep whenever any fzf-lua window exists) is
--- what keeps the reaper useful: an fzf-lua window can sit open and forgotten for hours -- one live
--- session had a `git_files` picker open for 11 -- and a blanket skip would mean the ~200 orphans
--- left by *earlier, already-closed* pickers were never collected.
---
--- Returns nil if fzf-lua's internals have moved, so the caller can fall back to skipping.
---@return table<integer, true>|nil
local function fzf_owned()
  -- `package.loaded` rather than `require`: never force a lazy plugin to load just to ask.
  local fzfwin = package.loaded['fzf-lua.win']
  if not fzfwin or type(fzfwin.__SELF) ~= 'function' then
    return {}
  end
  local ok, win = pcall(fzfwin.__SELF)
  if not ok then
    return nil
  end
  if not win then
    return {}
  end
  local prev = win._previewer
  if not prev then
    return {}
  end
  local owned = {}
  if type(prev.preview_bufnr) == 'number' then
    owned[prev.preview_bufnr] = true
  end
  -- `bcache.buffers` is keyed by bufnr; it is a private field, hence the guarded read.
  local got, err = pcall(function()
    for buf in pairs(prev.bcache.buffers) do
      owned[buf] = true
    end
  end)
  if not got then
    vim.notify_once('bufreap: cannot read fzf-lua preview cache (' .. tostring(err) .. '); skipping sweeps while a picker is open', vim.log.levels.WARN)
    return nil
  end
  return owned
end

--- True while a telescope picker is on screen.
---
--- Unlike fzf-lua, telescope holds input focus, so a picker is never left open for hours -- there
--- is nothing to gain from per-buffer accounting, and skipping the sweep outright is both simpler
--- and safe against telescope's own previewer bookkeeping.
---
--- The prompt buffer must be *displayed*, not merely loaded. Telescope leaves the prompt buffer
--- behind after a picker closes (measured: still loaded, unlisted, in no window), so an
--- existence check reports a picker forever after the first one and silently disables every
--- sweep for the rest of the session.
---@return boolean
local function telescope_active()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'TelescopePrompt' then
        return true
      end
    end
  end
  return false
end

--- Byte size of a loaded buffer's text (`nvim_buf_get_offset` returns -1 when unloaded).
---@param buf integer
---@return integer
local function buf_bytes(buf)
  local ok, bytes = pcall(vim.api.nvim_buf_get_offset, buf, vim.api.nvim_buf_line_count(buf))
  return (ok and bytes > 0) and bytes or 0
end

--- Every orphan preview buffer, with the ones not yet old enough reported separately.
---
--- Buffers reach the preview window through `win_set_buf_noautocmd`, so they never fire BufEnter
--- and never get stamped by the autocmd below. Stamping them here on first sight is what gives
--- them a full `idle_ms` grace period instead of being wiped the moment they are noticed.
---@return integer[] reapable, integer[] waiting
function M.candidates()
  local shown = displayed()
  local owned = fzf_owned() or {}
  local cur = vim.api.nvim_get_current_buf()
  local alt = vim.fn.bufnr '#'
  local now = vim.uv.now()
  local reapable, waiting = {}, {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == 'nofile'
      and vim.bo[buf].bufhidden == 'hide'
      and not vim.bo[buf].buflisted
      and not vim.bo[buf].modified
      and not KEEP_FT[vim.bo[buf].filetype]
      and not shown[buf]
      and not owned[buf]
      and buf ~= cur
      and buf ~= alt
    then
      local seen = vim.b[buf].bufreap_seen
      if not seen then
        vim.b[buf].bufreap_seen = now
        waiting[#waiting + 1] = buf
      elseif now - seen >= M.idle_ms then
        reapable[#reapable + 1] = buf
      else
        waiting[#waiting + 1] = buf
      end
    end
  end
  return reapable, waiting
end

--- File buffers that have sat hidden long enough to be worth unloading.
---
--- Unloading (rather than deleting) frees the text, the tree-sitter tree and the parser in one
--- step while leaving the buffer listed, so `:b <name>`, `:ls` and the tabline are unchanged. It is
--- safe to do behind the user's back only because `init.lua` sets `undofile`: the undo history is
--- reread from `undodir` when the buffer loads again. Without that this would silently discard it.
---
--- Measured on one 12-day session: 38 of 52 live tree-sitter trees were on hidden buffers,
--- ~104MB of the ~249MB total.
---@return integer[]
function M.unload_candidates()
  local shown = displayed()
  local cur = vim.api.nvim_get_current_buf()
  local alt = vim.fn.bufnr '#'
  local now = vim.uv.now()
  local out = {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ''
      and vim.bo[buf].buflisted
      -- Never unload unsaved work; `:bunload` would refuse anyway, but say so explicitly.
      and not vim.bo[buf].modified
      and not KEEP_FT[vim.bo[buf].filetype]
      and not shown[buf]
      and buf ~= cur
      and buf ~= alt
    then
      -- The content has to actually exist on disk, or unloading destroys it. A buffer named after
      -- a file that was deleted or renamed underneath us fails this and stays loaded.
      local name = vim.api.nvim_buf_get_name(buf)
      local seen = vim.b[buf].bufreap_seen
      if name ~= '' and vim.uv.fs_stat(name) and seen and now - seen >= M.unload_ms then
        out[#out + 1] = buf
      end
    end
  end
  return out
end

--- Drop stale extmarks that a plugin renders but never clears.
---@return integer marks cleared
local function sweep_extmarks()
  local ns = vim.api.nvim_get_namespaces()['nvim-treesitter-context']
  if not ns then
    return 0
  end
  local cleared = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, 0, -1, {})
      if ok and #marks > CONTEXT_MARK_RATIO * math.max(vim.api.nvim_buf_line_count(buf), 1) then
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
        cleared = cleared + #marks
      end
    end
  end
  return cleared
end

--- Delete every reapable orphan. No-op while a picker is open.
--- Delete orphan previews and unload long-hidden file buffers. No-op while a picker is open.
---@return integer deleted, integer bytes freed, integer marks cleared, integer unloaded
function M.sweep()
  local ts_open = telescope_active()

  -- Retire the throttle timers telescope drops on the floor. Done before the fzf-lua guard and
  -- outside the buffer passes: these handles have nothing to do with buffers, so an unreadable
  -- preview cache must not also block reclaiming them.
  if not ts_open then
    local lg = package.loaded['leakguard']
    if lg and lg.drain_telescope_timers then
      pcall(lg.drain_telescope_timers)
    end
  end

  -- `nil` means fzf-lua's cache could not be read, so which buffers are in use is unknown.
  if ts_open or fzf_owned() == nil then
    return 0, 0, 0, 0
  end

  local bytes = 0
  local reapable = M.candidates()
  for _, buf in ipairs(reapable) do
    bytes = bytes + buf_bytes(buf)
    -- BufDelete fires from here, so `autocommands.lua` releases any parked highlighter itself.
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  local unloadable = M.unload_candidates()
  local unloaded = 0
  for _, buf in ipairs(unloadable) do
    local n = buf_bytes(buf)
    -- `unload = true` is `:bunload`: frees the text and everything hanging off it, keeps it listed.
    if pcall(vim.api.nvim_buf_delete, buf, { unload = true }) then
      unloaded = unloaded + 1
      bytes = bytes + n
    end
  end

  return #reapable, bytes, sweep_extmarks(), unloaded
end

-- Reloading this module (`:source`, a lazy.nvim reload, or a `dofile` from a debugging session)
-- would otherwise stack a second repeating timer on top of the first, and the old one is a
-- file-local that nothing can reach afterwards. Park the handle somewhere global so a later load
-- can retire its predecessor -- the same "leaving a handle unreachable is how you leak it" lesson
-- that the timer teardown in `autocommands.lua` encodes.
if _G.__bufreap_timer then
  pcall(function()
    _G.__bufreap_timer:stop()
    if not _G.__bufreap_timer:is_closing() then
      _G.__bufreap_timer:close()
    end
  end)
end

local timer = vim.uv.new_timer()
_G.__bufreap_timer = timer

local group = vim.api.nvim_create_augroup('BufReap', { clear = true })

-- A buffer the user actually visits is not an orphan; re-stamping keeps it out of reach of the
-- idle threshold for as long as it stays in use.
vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
  group = group,
  desc = 'Mark a buffer as recently used, for the orphan reaper',
  callback = function(ctx)
    if vim.api.nvim_buf_is_valid(ctx.buf) then
      vim.b[ctx.buf].bufreap_seen = vim.uv.now()
    end
  end,
})

vim.api.nvim_create_autocmd('FocusLost', {
  group = group,
  desc = 'Reap orphaned preview buffers when stepping away',
  callback = function()
    vim.schedule(M.sweep)
  end,
})

-- Same shape as the `restore_timer` teardown in `autocommands.lua`: stop and close, or libuv holds
-- the handle open past exit.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end,
})

timer:start(
  M.sweep_ms,
  M.sweep_ms,
  vim.schedule_wrap(function()
    M.sweep()
  end)
)

vim.api.nvim_create_user_command('BufReap', function()
  local n, bytes, marks, unloaded = M.sweep()
  vim.notify(
    string.format('BufReap: deleted %d preview buffer(s), unloaded %d file buffer(s), %.2f MB, %d stale extmark(s)', n, unloaded, bytes / 1048576, marks)
  )
end, { desc = 'Wipe orphaned picker preview buffers and unload long-hidden file buffers' })

vim.api.nvim_create_user_command('BufReapStatus', function()
  local reapable, waiting = M.candidates()
  local bytes = 0
  local lines = {}
  for _, buf in ipairs(reapable) do
    local b = buf_bytes(buf)
    bytes = bytes + b
    local name = vim.api.nvim_buf_get_name(buf)
    lines[#lines + 1] = string.format(
      '  buf=%-5d %7.2f MB  ft=%-12s ts=%-5s %s',
      buf,
      b / 1048576,
      vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype or '-',
      tostring(vim.treesitter.highlighter.active[buf] ~= nil),
      name ~= '' and name:sub(-60) or (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''):sub(1, 60)
    )
  end
  local unloadable = M.unload_candidates()
  local ubytes = 0
  if #unloadable > 0 then
    lines[#lines + 1] = 'unloadable file buffers (kept listed):'
    for _, buf in ipairs(unloadable) do
      local b = buf_bytes(buf)
      ubytes = ubytes + b
      lines[#lines + 1] = string.format(
        '  buf=%-5d %7.2f MB  ts=%-5s %s',
        buf,
        b / 1048576,
        tostring(vim.treesitter.highlighter.active[buf] ~= nil),
        vim.api.nvim_buf_get_name(buf):sub(-58)
      )
    end
  end
  local owned = fzf_owned()
  table.insert(
    lines,
    1,
    string.format(
      'BufReap: %d preview reapable (%.2f MB), %d unloadable (%.2f MB), %d waiting | telescope_open=%s fzf_owned=%s',
      #reapable,
      bytes / 1048576,
      #unloadable,
      ubytes / 1048576,
      #waiting,
      tostring(telescope_active()),
      owned and tostring(vim.tbl_count(owned)) or 'unreadable'
    )
  )
  vim.notify(table.concat(lines, '\n'))
end, { desc = 'List orphaned picker preview buffers without deleting them' })

--- One-shot memory picture, folded in from the ad-hoc probes used to find these leaks.
---
--- The number people get wrong is resident vs footprint: a session showing "3.4GB" in Activity
--- Monitor was 179MB resident, the rest being allocator arenas at their high-water mark, mapped
--- and swapped but dead. Only a restart returns those, so the report prints both and says so.
---@return string
function M.report()
  local pid = vim.fn.getpid()
  local function sh(cmd)
    local h = io.popen(cmd)
    if not h then
      return ''
    end
    local r = h:read '*a' or ''
    h:close()
    return r
  end

  local L = {}
  local function p(...)
    L[#L + 1] = table.concat({ ... }, ' ')
  end

  local rss = tonumber(sh('ps -o rss= -p ' .. pid):match '%d+' or 0) / 1024
  local fp = sh('footprint -p ' .. pid .. ' 2>/dev/null'):match 'phys_footprint:%s+([%d%.]+ %a+)' or '?'
  local peak = sh('footprint -p ' .. pid .. ' 2>/dev/null'):match 'phys_footprint_peak:%s+([%d%.]+ %a+)' or '?'
  local regions = tonumber(sh('vmmap -summary ' .. pid .. " 2>/dev/null | awk '/^VM_ALLOCATE/{print $NF}'"):match '%d+' or 0)

  p(string.format('resident %.0f MB | footprint %s (peak %s) | VM_ALLOCATE regions %d', rss, fp, peak, regions))
  p '  resident is what costs RAM; footprint counts swapped/compressed dead arenas that only a restart returns.'
  p(string.format '  (a fresh nvim with this config has ~186 regions; far above that is leftover high-water mark)')

  local shown = displayed()
  local loaded, listed, bytes = 0, 0, 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      loaded = loaded + 1
      bytes = bytes + buf_bytes(b)
    end
    if vim.bo[b].buflisted then
      listed = listed + 1
    end
  end
  p(string.format('buffers: %d loaded, %d listed, %.1f MB text', loaded, listed, bytes / 1048576))

  local tvis, thid, bvis, bhid = 0, 0, 0, 0
  for b in pairs(vim.treesitter.highlighter.active or {}) do
    local n = buf_bytes(b)
    if shown[b] then
      tvis, bvis = tvis + 1, bvis + n
    else
      thid, bhid = thid + 1, bhid + n
    end
  end
  p(string.format('treesitter: %d visible (%.1f MB src), %d hidden (%.1f MB src, reclaimable)', tvis, bvis / 1048576, thid, bhid / 1048576))

  local heap = collectgarbage 'count'
  collectgarbage 'collect'
  local live = collectgarbage 'count'
  p(string.format('lua heap: %.0f MB, %.0f MB live after full GC (%.0f%% was garbage)', heap / 1024, live / 1024, heap > 0 and (heap - live) / heap * 100 or 0))

  local h = {}
  vim.uv.walk(function(x)
    if not x:is_closing() then
      local t = x:get_type()
      h[t] = (h[t] or 0) + 1
    end
  end)
  local hs = {}
  for k, v in pairs(h) do
    hs[#hs + 1] = string.format('%s=%d', k, v)
  end
  table.sort(hs)
  p('libuv handles: ' .. table.concat(hs, ' '))

  local reapable, waiting = M.candidates()
  p(
    string.format(
      'reaper: %d preview reapable, %d unloadable, %d waiting, %d autocmds',
      #reapable,
      #M.unload_candidates(),
      #waiting,
      #vim.api.nvim_get_autocmds {}
    )
  )
  return table.concat(L, '\n')
end

vim.api.nvim_create_user_command('MemReport', function()
  vim.notify(M.report())
end, { desc = "Report where this session's memory is going" })

return M
