-- The details of an item in a float: `<backend> show --plain -- ID`, rendered as Markdown.

local util = require 'liveq.util'

local M = {}

--- Puts the cursor of the current window on the first match of a query, and the query's words in the search register
--- (highlighted, `n`/`N` go through them). The words come from the backend (`terms -- QUERY`, sources with `match`);
--- the first match is the first one of the word that is the rarest in the text, below its title line, as in the preview.
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

--- Runs `show --plain` for a window `width` wide. An item that is a part of a bigger text (a message of a mail
--- thread) gives the line where it starts through $LIVEQ_MATCH_FILE (a number followed by `t`, see cli.lua): the text
--- and that line, nil when there is none.
local function show_plain(source, id, width)
  local file = vim.fn.tempname()
  local out = util.run(source, { 'show', '--plain', '--', id }, { env = { LIVEQ_WIDTH = tostring(width), LIVEQ_MATCH_FILE = file } })
  local start
  local f = io.open(file, 'r')
  if f then
    f:read '*l'
    f:read '*l'
    start = tonumber(((f:read '*l' or ''):match '(%d+)t'))
    f:close()
    os.remove(file)
  end
  return out, start
end

--- Goes to the start of the item within the text (`start`), else to the first match of the query.
local function position(source, opts, start)
  goto_matches(source, opts and opts.query, start ~= nil)
  if start and start <= vim.api.nvim_buf_line_count(0) then
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd 'normal! zt'
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
  local out, start = show_plain(source, id, width - 1)
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
  position(source, opts, start)
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
  local out, start = show_plain(source, id, width)
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
  position(source, opts, start)
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
