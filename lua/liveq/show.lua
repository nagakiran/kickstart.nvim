-- The details of an item in a float: `<backend> show --plain -- ID`, rendered as Markdown.

local util = require 'liveq.util'

local M = {}

--- Puts the query's words in the search register (highlighted, `n`/`N` go through them), and unless `keep_cursor`, the
--- cursor of the current window on the first match. The words come from the backend (`terms -- QUERY`, sources with
--- `match`). Which match is first is the backend's call (see show_plain), so that a buffer starts where the picker's
--- preview does; this one (the first of the word that is the rarest in the text, below its title line) is only for a
--- backend that gave none.
local function goto_matches(source, query, keep_cursor)
  if not source.match or not query or vim.trim(query) == '' then
    return
  end
  local out = util.run(source, { 'terms', '--', query }, { silent = true })
  local ok, terms = pcall(vim.json.decode, out or '')
  if not ok or type(terms) ~= 'table' or #terms == 0 then
    return
  end
  local patterns = {}
  for _, words in ipairs(terms) do
    table.insert(patterns, [[\<]] .. table.concat(words, [[\_W\+]]))
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local best_count, best_pos
  for _, pattern in ipairs(patterns) do
    local re = vim.regex([[\c]] .. pattern)
    local count, pos = 0, nil
    for n = 2, #lines do
      local col = re:match_str(lines[n])
      if col then
        count = count + 1
        pos = pos or { n, col }
      end
    end
    if pos and (not best_count or count < best_count) then
      best_count, best_pos = count, pos
    end
  end
  local all = [[\c\%(]] .. table.concat(patterns, [[\|]]) .. [[\)]]
  vim.fn.setreg('/', all)
  vim.fn.histadd('/', all)
  vim.v.hlsearch = 1
  if best_pos and not keep_cursor then
    vim.api.nvim_win_set_cursor(0, best_pos)
    vim.cmd 'normal! zz'
  end
end

--- Runs `show --plain` for a window `width` wide, with `--match QUERY` for a source with `match`, through
--- $LIVEQ_MATCH_FILE (the format of the picker's preview, see cli.lua) learning:
---   start: where the item starts in a bigger text (a message of a mail thread: the number followed by `t`);
---   first: the line of the match the backend shows first, the same one the picker's preview starts at.
--- Returns the text, start and first (nil when there is none).
local function show_plain(source, id, width, query)
  local file = vim.fn.tempname()
  local args = { 'show', '--plain' }
  if source.match and query and vim.trim(query) ~= '' then
    vim.list_extend(args, { '--match', query })
  end
  vim.list_extend(args, { '--', id })
  local out = util.run(source, args, { env = { LIVEQ_WIDTH = tostring(width), LIVEQ_MATCH_FILE = file } })
  local start, first
  local f = io.open(file, 'r')
  if f then
    f:read '*l'
    local index = tonumber(f:read '*l' or '')
    local numbers = vim.split(f:read '*l' or '', ' ', { trimempty = true })
    f:close()
    os.remove(file)
    for _, n in ipairs(numbers) do
      start = start or tonumber(n:match '^(%d+)t$')
    end
    first = index and numbers[index] and tonumber(numbers[index]:match '^%d+$')
  end
  return out, start, first
end

--- Goes to the start of the item within the text (`start`), else to the backend's first match of the query
--- (`first`), else to goto_matches' own.
local function position(source, opts, start, first)
  local query = opts and opts.query
  goto_matches(source, query, start ~= nil or first ~= nil)
  local count = vim.api.nvim_buf_line_count(0)
  if start and start <= count then
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd 'normal! zt'
  elseif first and first <= count then
    vim.api.nvim_win_set_cursor(0, { first, 0 })
    pcall(vim.fn.search, vim.fn.getreg '/', 'cW', first) -- on the word itself, when it is in this line
    vim.cmd 'normal! zz'
  end
end

--- opts.query: the search the item was found with; the cursor goes to its first match.
function M.show(source, id, opts)
  id = (id and id ~= '') and id or util.id_under_cursor(source)
  if not id then
    vim.notify('No ' .. (source.item_name or 'item') .. ' under the cursor', vim.log.levels.WARN)
    return
  end
  local width = math.min(math.floor(vim.o.columns * 0.7), 110)
  local out, start, first = show_plain(source, id, width - 1, opts and opts.query)
  if not out then
    return
  end
  local lines = vim.split(vim.trim(out), '\n', { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = ' ' .. id .. ' ',
  })
  vim.wo[win].wrap = true
  position(source, opts, start, first)
  for _, lhs in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', lhs, '<cmd>close<CR>', { buffer = buf, nowait = true })
  end
  M.map_gx(buf, function()
    if source.url then
      M.open(source, id)
    end
  end)
end

--- Opens an item in a buffer of its own in the current window (`<backend> show --plain -- ID`, as Markdown), named
--- `liveq://SOURCE/ID` so that opening it again reuses the buffer, with its text refreshed. opts.query: the search the
--- item was found with; the cursor goes to its first match.
function M.buffer(source, id, opts)
  id = (id and id ~= '') and id or util.id_under_cursor(source)
  if not id then
    vim.notify('No ' .. (source.item_name or 'item') .. ' under the cursor', vim.log.levels.WARN)
    return
  end
  -- lay the text out as wide as the window's text area (without the number, sign and fold columns)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local width = info.width - info.textoff - 1
  local out, start, first = show_plain(source, id, width, opts and opts.query)
  if not out then
    return
  end
  local name = ('liveq://%s/%s'):format(source.name, id)
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.trim(out), '\n', { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  position(source, opts, start, first)
  M.map_gx(buf, function()
    if source.url then
      M.open(source, id)
    end
  end)
end

--- Maps `gx` in BUF: the link under the cursor in the browser, else `fallback` (e.g. the item itself).
function M.map_gx(buf, fallback)
  vim.keymap.set('n', 'gx', function()
    local url = util.url_under_cursor()
    if url then
      vim.ui.open(url)
    else
      fallback()
    end
  end, { buffer = buf, desc = 'Open the link under the cursor, else the item, in the browser' })
end

--- Opens an item in the browser: `<backend> url -- ID`.
function M.open(source, id)
  id = (id and id ~= '') and id or util.id_under_cursor(source)
  if not id then
    vim.notify('No ' .. (source.item_name or 'item') .. ' under the cursor', vim.log.levels.WARN)
    return
  end
  local url = util.run(source, { 'url', '--', id })
  if url and vim.trim(url) ~= '' then
    vim.ui.open(vim.trim(url))
  end
end

return M
