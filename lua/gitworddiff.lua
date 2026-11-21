-- Word-level highlighting for unified diffs shown in fugitive buffers (the inline `=` diff in
-- :Git status, commit objects, :Git diff output). A run of '-' lines followed by a run of '+'
-- lines is diffed token by token, and only the changed tokens get GitWordDel / GitWordAdd, the
-- way delta or GitHub do. Marks are ephemeral (decoration provider), so they follow every
-- re-render of the buffer; the per-buffer computation is cached on changedtick.
local M = {}

local ns = vim.api.nvim_create_namespace 'gitworddiff'
local FILETYPES = { fugitive = true, git = true, diff = true }
local MAX_BLOCK_LINES = 200 -- larger -/+ blocks are rewrites; word marks would be noise
local MAX_CHANGED_RATIO = 0.7 -- skip a block when most of it changed anyway
local NL = '\1' -- token standing for a line break inside a block

local cache = {} -- buf -> { tick = n, rows = { [row] = { {col_s, col_e, hl}, ... } } }

local function set_hl()
  local dark = vim.o.background == 'dark'
  vim.api.nvim_set_hl(0, 'GitWordDel', { default = true, bg = dark and '#7a2f2f' or '#ffb3b3' })
  vim.api.nvim_set_hl(0, 'GitWordAdd', { default = true, bg = dark and '#3d5f2a' or '#b3f0b3' })
end

-- Split into words, whitespace runs and single (UTF-8) characters, with 0-based byte offsets.
local function tokenize(s, toks, pos, row, base)
  local i, n = 1, #s
  while i <= n do
    local _, e = s:find('^[%w_]+', i)
    if not e then
      _, e = s:find('^%s+', i)
    end
    if not e then
      _, e = s:find('^[\1-\127\194-\244][\128-\191]*', i)
    end
    e = e or i
    toks[#toks + 1] = s:sub(i, e)
    pos[#pos + 1] = { row, base + i - 1, base + e }
    i = e + 1
  end
end

local function block_tokens(lines, first_row)
  local toks, pos = {}, {}
  for k, line in ipairs(lines) do
    if k > 1 then
      toks[#toks + 1] = NL
      pos[#pos + 1] = false
    end
    tokenize(line:sub(2), toks, pos, first_row + k - 1, 1)
  end
  return toks, pos
end

local function mark_range(rows, pos, from, count, hl)
  for t = from, from + count - 1 do
    local p = pos[t]
    if p then
      local r = rows[p[1]] or {}
      rows[p[1]] = r
      local last = r[#r]
      if last and last[3] == hl and last[2] == p[2] then
        last[2] = p[3] -- extend the previous mark over adjacent tokens
      else
        r[#r + 1] = { p[2], p[3], hl }
      end
    end
  end
end

local function diff_block(rows, del, del_row, add, add_row)
  if #del > MAX_BLOCK_LINES or #add > MAX_BLOCK_LINES then
    return
  end
  local ta, pa = block_tokens(del, del_row)
  local tb, pb = block_tokens(add, add_row)
  local hunks = vim.text.diff(table.concat(ta, '\n') .. '\n', table.concat(tb, '\n') .. '\n', { result_type = 'indices', algorithm = 'histogram' })
  local changed = 0
  for _, h in ipairs(hunks) do
    changed = changed + h[2] + h[4]
  end
  if changed > MAX_CHANGED_RATIO * (#ta + #tb) then
    return
  end
  for _, h in ipairs(hunks) do
    if h[2] > 0 then
      mark_range(rows, pa, h[1], h[2], 'GitWordDel')
    end
    if h[4] > 0 then
      mark_range(rows, pb, h[3], h[4], 'GitWordAdd')
    end
  end
end

local function is_header(line)
  return line:find '^%-%-%- ' or line:find '^%+%+%+ '
end

local function compute(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows = {}
  local i, n = 1, #lines
  while i <= n do
    local c = lines[i]:sub(1, 1)
    if c == '-' and not is_header(lines[i]) then
      local ds = i
      while i <= n and lines[i]:sub(1, 1) == '-' and not is_header(lines[i]) do
        i = i + 1
      end
      local as = i
      while i <= n and lines[i]:sub(1, 1) == '+' and not is_header(lines[i]) do
        i = i + 1
      end
      if i > as then
        diff_block(rows, vim.list_slice(lines, ds, as - 1), ds - 1, vim.list_slice(lines, as, i - 1), as - 1)
      end
    else
      i = i + 1
    end
  end
  return rows
end

function M.setup()
  set_hl()
  vim.api.nvim_create_autocmd('ColorScheme', { group = vim.api.nvim_create_augroup('gitworddiff', {}), callback = set_hl })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = 'gitworddiff',
    callback = function(ev)
      cache[ev.buf] = nil
    end,
  })

  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      if not FILETYPES[vim.bo[buf].filetype] then
        return false
      end
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local c = cache[buf]
      if not c or c.tick ~= tick then
        c = { tick = tick, rows = compute(buf) }
        cache[buf] = c
      end
      return next(c.rows) ~= nil
    end,
    on_line = function(_, _, buf, row)
      local marks = cache[buf] and cache[buf].rows[row]
      if not marks then
        return
      end
      for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, m[1], { end_col = m[2], hl_group = m[3], ephemeral = true, priority = 200 })
      end
    end,
  })
end

return M
