-- A scratch buffer to write a query in, with the source's completion (see cmp.lua); <CR> in normal mode searches.

local util = require 'liveq.util'

local M = {}

local function buffer_query(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.trim((table.concat(lines, ' '):gsub('%s+', ' ')))
end

function M.open(source, query)
  local path = vim.fn.tempname() .. '.' .. (source.extension or source.filetype or 'txt')
  local lines = {}
  if query and query ~= '' then
    local pretty = source.split_clauses and source.split_clauses(query) or query
    lines = vim.split(pretty, '\n', { plain = true })
  end
  vim.fn.writefile(lines, path)
  vim.cmd('botright 8split ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = 'wipe'
  -- several sources may share a filetype (e.g. two mailboxes); completion asks the one that opened the buffer
  vim.b[buf].liveq_source = source.name
  vim.keymap.set('n', '<CR>', function()
    require('liveq.picker').search(source, buffer_query(buf))
  end, { buffer = buf, desc = 'Search ' .. source.title .. ' with this query' })
  -- :w searches too, so the edited query goes back to the picker
  vim.api.nvim_create_autocmd('BufWritePost', {
    buffer = buf,
    desc = 'Search ' .. source.title .. ' with the saved query',
    callback = function()
      -- read now: after :wq the buffer is wiped (bufhidden) before the scheduled search runs
      local query = buffer_query(buf)
      vim.schedule(function()
        vim.cmd 'stopinsert'
        require('liveq.picker').search(source, query)
      end)
    end,
  })
  if source.validate then
    vim.keymap.set('n', '<localleader>v', function()
      local out = util.run(source, { 'validate', '--', buffer_query(buf) })
      if out then
        vim.notify 'The query is valid'
      end
    end, { buffer = buf, desc = 'Validate this query' })
  end
  vim.cmd 'normal! G'
  vim.cmd 'startinsert!'
end

return M
