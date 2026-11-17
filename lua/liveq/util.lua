-- Helpers shared by the parts of liveq: running a source's backend command and reading its output.
--
-- Also loaded by `cli.lua` under `nvim -l`, so it must not depend on plugins or on the user's config.

local M = {}

--- The backend command of a source, as a list.
function M.cmd(source)
  local cmd = source.cmd
  if type(cmd) == 'function' then
    cmd = cmd()
  end
  if type(cmd) == 'string' then
    cmd = { cmd }
  end
  return vim.deepcopy(cmd)
end

--- The backend command of a source, quoted for a shell; e.g. for the bindings of fzf.
function M.shell_cmd(source)
  return table.concat(vim.tbl_map(vim.fn.shellescape, M.cmd(source)), ' ')
end

--- Runs a subcommand of a source's backend synchronously; returns its stdout, or nil after notifying the error.
function M.run(source, args, opts)
  opts = opts or {}
  local cmd = M.cmd(source)
  vim.list_extend(cmd, args)
  -- opts.env: extra environment variables, e.g. LIVEQ_WIDTH (the text width of the window that shows the output)
  local ok, job = pcall(vim.system, cmd, { text = true, env = opts.env })
  if not ok then
    vim.notify(tostring(job), vim.log.levels.ERROR, { title = 'liveq' })
    return nil
  end
  local result = job:wait(opts.timeout or 30000)
  if result.code ~= 0 then
    if not opts.silent then
      vim.notify(vim.trim((result.stderr or '') .. (result.stdout or '')), vim.log.levels.ERROR, { title = 'liveq: ' .. (source.name or '') })
    end
    return nil
  end
  return result.stdout or ''
end

--- An item of a search: `id \t display \t url \t title`. Hint and error lines have no id; fzf-lua may strip the empty
--- field they start with, so the id is only trusted when it matches the source's `id_pattern` (a pattern, or a list
--- of them when there are several kinds of items, e.g. the threads and the messages of a mailbox).
function M.parse_line(source, line)
  local parts = vim.split(line, '\t', { plain = true })
  local id = parts[1] or ''
  local patterns = type(source.id_pattern) == 'table' and source.id_pattern or { source.id_pattern }
  if source.id_pattern then
    local ok = false
    for _, pattern in ipairs(patterns) do
      ok = ok or id:match(pattern) ~= nil
    end
    if not ok then
      id = ''
    end
  end
  return { id = id, url = parts[3] or '', title = parts[4] or '' }
end

--- The items of the lines selected in fzf, without the hint and error lines.
function M.items(source, selected)
  local items = {}
  for _, line in ipairs(selected or {}) do
    local item = M.parse_line(source, line)
    if item.id ~= '' then
      table.insert(items, item)
    end
  end
  return items
end

--- The id under the cursor, when the source can recognise one in text (`cursor_id_pattern`).
function M.id_under_cursor(source)
  if not source.cursor_id_pattern then
    return nil
  end
  return vim.fn.expand('<cWORD>'):match(source.cursor_id_pattern)
end

--- Replaces the characters [start, finish) of `text` (offsets in characters, as the backends report them).
function M.replace(text, start, finish, insert)
  local before = vim.fn.strcharpart(text, 0, start)
  local after = vim.fn.strcharpart(text, finish)
  return before .. insert .. after, vim.fn.strchars(before)
end

--- The links in a line of text, in order: { url =, start =, finish = } with byte columns (1-based, inclusive).
--- Punctuation that ends a sentence is left out, and a closing bracket unless the link has its opening one.
function M.urls(line)
  local found, init = {}, 1
  while true do
    local start, finish = line:find("https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+", init)
    if not start then
      break
    end
    local url = line:sub(start, finish)
    while true do
      local last = url:sub(-1)
      local strip = last:match '[%.,;:!%?\'"]'
        or (last == ')' and select(2, url:gsub('%(', '')) < select(2, url:gsub('%)', '')))
        or (last == ']' and select(2, url:gsub('%[', '')) < select(2, url:gsub('%]', '')))
      if not strip then
        break
      end
      url = url:sub(1, -2)
    end
    table.insert(found, { url = url, start = start, finish = start + #url - 1 })
    init = finish + 1
  end
  return found
end

--- The link under the cursor of the current window, nil when there is none.
function M.url_under_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for _, u in ipairs(M.urls(vim.api.nvim_get_current_line())) do
    if col >= u.start and col <= u.finish then
      return u.url
    end
  end
end

return M
