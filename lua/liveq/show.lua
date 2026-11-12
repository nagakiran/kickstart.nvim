-- The details of an item in a float: `<backend> show --plain -- ID`, rendered as Markdown.

local util = require 'liveq.util'

local M = {}

function M.show(source, id)
  id = (id and id ~= '') and id or util.id_under_cursor(source)
  if not id then
    vim.notify('No ' .. (source.item_name or 'item') .. ' under the cursor', vim.log.levels.WARN)
    return
  end
  local out = util.run(source, { 'show', '--plain', '--', id })
  if not out then
    return
  end
  local lines = vim.split(vim.trim(out), '\n', { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  local width = math.min(math.floor(vim.o.columns * 0.7), 110)
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
  for _, lhs in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', lhs, '<cmd>close<CR>', { buffer = buf, nowait = true })
  end
  if source.url then
    vim.keymap.set('n', 'gx', function()
      M.open(source, id)
    end, { buffer = buf, desc = 'Open in browser' })
  end
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
