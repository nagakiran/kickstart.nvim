-- An nvim-cmp source that completes the query of a buffer whose filetype belongs to a liveq source, with
-- `<backend> complete -f json -c OFFSET -- QUERY`.

local M = {}

local CMP_KIND = { field = 'Field', operator = 'Operator', value = 'Value', ['function'] = 'Function', keyword = 'Keyword' }

--- The (0-based) row and byte column of a character offset into `lines` joined with newlines.
local function position_of(lines, offset)
  for row, line in ipairs(lines) do
    local length = vim.fn.strchars(line)
    if offset <= length then
      return row - 1, vim.fn.byteidx(line, offset)
    end
    offset = offset - length - 1
  end
  return #lines - 1, #(lines[#lines] or '')
end

--- The text to insert: a snippet with `$0` where the cursor goes when it does not go at the end (e.g. `in ($0)`).
local function edit_text(text, cursor_offset)
  local before = vim.fn.strcharpart(text, 0, cursor_offset)
  local after = vim.fn.strcharpart(text, cursor_offset)
  if after == '' then
    return text, 1 -- plain text
  end
  local escape = function(s)
    return (s:gsub('[%$}\\]', '\\%0'))
  end
  return escape(before) .. '$0' .. escape(after), 2 -- snippet
end

function M.new(registry)
  local source = { registry = registry, job = nil }

  local function current()
    return registry.for_buffer(0)
  end

  function source:get_debug_name()
    return 'liveq'
  end

  function source:is_available()
    return current() ~= nil
  end

  function source:get_trigger_characters()
    local spec = current()
    return spec and spec.trigger_characters or { ' ' }
  end

  function source:get_keyword_pattern()
    local spec = current()
    return spec and spec.keyword_pattern or [[\k\+]]
  end

  function source:complete(_, callback)
    local spec = current()
    if not spec then
      callback { items = {} }
      return
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local offset = 0
    for row = 1, cursor[1] - 1 do
      offset = offset + vim.fn.strchars(lines[row]) + 1
    end
    offset = offset + vim.fn.strchars(lines[cursor[1]]:sub(1, cursor[2]))
    local text = table.concat(lines, '\n')

    if self.job then
      pcall(function()
        self.job:kill 'sigterm'
      end)
    end
    local cmd = require('liveq.util').cmd(spec)
    vim.list_extend(cmd, { 'complete', '-f', 'json', '-c', tostring(offset), '--', text })
    local ok, job = pcall(vim.system, cmd, { text = true }, function(result)
      vim.schedule(function()
        local decoded, data = pcall(vim.json.decode, result.stdout or '')
        if result.code ~= 0 or not decoded or type(data) ~= 'table' then
          callback { items = {}, isIncomplete = true }
          return
        end
        local srow, scol = position_of(lines, data.replace_start)
        local erow, ecol = position_of(lines, data.replace_end)
        local range = {
          start = { line = srow, character = vim.fn.strchars((lines[srow + 1] or ''):sub(1, scol)) },
          ['end'] = { line = erow, character = vim.fn.strchars((lines[erow + 1] or ''):sub(1, ecol)) },
        }
        local kinds = require('cmp').lsp.CompletionItemKind
        local items = {}
        for index, c in ipairs(data.candidates or {}) do
          local new_text, format = edit_text(c.insert, c.cursor_offset)
          table.insert(items, {
            label = c.display,
            filterText = c.insert,
            sortText = ('%05d'):format(index),
            kind = kinds[CMP_KIND[c.kind] or 'Text'] or kinds.Text,
            labelDetails = (c.detail and c.detail ~= '') and { description = c.detail } or nil,
            textEdit = { newText = new_text, range = range },
            insertTextFormat = format,
          })
        end
        -- values come from the backend filtered by what is typed, so they are asked for again as the user types
        callback { items = items, isIncomplete = data.context == 'value' }
      end)
    end)
    self.job = ok and job or nil
  end

  return source
end

--- Registers the source with nvim-cmp and enables it for the filetype of every liveq source.
function M.setup(cmp, registry)
  cmp.register_source('liveq', M.new(registry))
  local done = {}
  for _, spec in pairs(registry.sources) do
    if spec.filetype and not done[spec.filetype] then
      done[spec.filetype] = true
      cmp.setup.filetype(spec.filetype, {
        sources = cmp.config.sources({ { name = 'liveq' } }, { { name = 'buffer' } }),
      })
    end
  end
end

return M
