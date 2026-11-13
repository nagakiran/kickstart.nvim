-- The command-line helper of liveq, run with `nvim -l` (no plugins, no user config; starts in ~40ms).
--
--   nvim -l cli.lua pick --cmd '<backend>' [--cursor N] -- QUERY
--
-- Completes QUERY with a picker on the terminal (fzf) and prints the new query. It only needs the backend's
-- `complete -f json` command, so a source does not have to implement a picker of its own; used by the TAB of `lq`
-- (shell) and of the fzf-lua picker. Exits with status 1, printing nothing, when nothing was picked.
--
--   nvim -l cli.lua match {first|next|prev} FILE     prints the fzf action that scrolls the preview to a match
--   nvim -l cli.lua scroll FILE                      sends `match first` to the fzf of $FZF_PORT (with curl)
--
-- FILE is the one a backend's `show --match` wrote ($LIVEQ_MATCH_FILE): the item's id, the index of the current match,
-- and the line numbers of the matches. `scroll` runs in the background after the preview is printed, since fzf only
-- applies a scroll offset given once the preview is complete; `match next/prev` are bound to keys of the picker.

local here = debug.getinfo(1, 'S').source:sub(2)
local lua_root = vim.fs.dirname(vim.fs.dirname(here))
package.path = lua_root .. '/?.lua;' .. lua_root .. '/?/init.lua;' .. package.path

local util = require 'liveq.util'

local function fail(message)
  if message then
    io.stderr:write('liveq: ' .. message .. '\n')
  end
  os.exit(1)
end

local function parse(args)
  local opts, rest = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--cmd' or a == '--cursor' then
      opts[a:sub(3)] = args[i + 1]
      i = i + 2
    else
      table.insert(rest, a)
      i = i + 1
    end
  end
  return opts, rest
end

local function pad(s, width)
  local n = vim.fn.strchars(s)
  return n >= width and s or (s .. string.rep(' ', width - n))
end

local function pick(opts, rest)
  local backend = opts.cmd or fail '--cmd is required'
  local query = rest[1] or ''
  local cursor = tonumber(opts.cursor)
  local complete_cmd = ('%s complete -f json %s-- %s'):format(backend, cursor and ('-c ' .. cursor .. ' ') or '', vim.fn.shellescape(query))
  local result = vim.system({ 'sh', '-c', complete_cmd }, { text = true }):wait(30000)
  if result.code ~= 0 then
    fail(vim.trim(result.stderr or ''))
  end
  local ok, data = pcall(vim.json.decode, result.stdout or '')
  if not ok or type(data) ~= 'table' then
    fail 'invalid output of the complete command'
  end
  local candidates = data.candidates or {}
  if #candidates == 0 then
    fail()
  end

  local width = 0
  for _, c in ipairs(candidates) do
    width = math.min(math.max(width, vim.fn.strchars(c.display)), 40)
  end
  local lines = {}
  for _, c in ipairs(candidates) do
    table.insert(lines, ('%s\t\27[2m%s\27[0m'):format(pad(c.display, width), vim.trim((c.kind or '') .. ' ' .. (c.detail or ''))))
  end
  local fzf_cmd = {
    'fzf',
    '--ansi',
    '--delimiter=\t',
    '--nth=1,2',
    '--height=40%',
    '--reverse',
    '--no-multi',
    '--print-query',
    '--prompt=' .. (data.context or 'pick') .. '> ',
  }
  if data.context ~= 'value' then
    vim.list_extend(fzf_cmd, { '--select-1', '--exit-0' })
  end
  local extra = os.getenv 'LIVEQ_FZF_OPTS'
  if extra and extra ~= '' then
    vim.list_extend(fzf_cmd, vim.split(extra, '%s+', { trimempty = true }))
  end
  -- fzf draws on /dev/tty by itself; its stdin is the list and its stdout the choice
  local picked = vim.system(fzf_cmd, { stdin = table.concat(lines, '\n'), text = true }):wait()
  if picked.code ~= 0 and picked.code ~= 1 then
    fail()
  end
  local out = vim.split(picked.stdout or '', '\n', { plain = true })
  local typed, selection = vim.trim(out[1] or ''), out[2] or ''

  local insert, cursor_offset
  if vim.trim(selection) ~= '' then
    local display = vim.trim(vim.split(selection, '\t', { plain = true })[1])
    for _, c in ipairs(candidates) do
      if c.display == display then
        insert, cursor_offset = c.insert, c.cursor_offset
        break
      end
    end
  elseif data.context == 'value' and typed ~= '' then
    -- a value that the backend does not suggest is taken as typed
    insert, cursor_offset = typed, vim.fn.strchars(typed)
  end
  if not insert then
    fail()
  end

  local new_text, start = util.replace(query, data.replace_start, data.replace_end, insert)
  local new_cursor = start + (cursor_offset or vim.fn.strchars(insert))
  if not cursor and vim.fn.strcharpart(new_text, new_cursor) == ')' then
    -- the caller puts the cursor at the end of what is printed, so a list is left open for its values
    new_text = vim.fn.strcharpart(new_text, 0, new_cursor)
  end
  io.stdout:write(new_text .. '\n')
end

--- The fzf action that shows the current match of FILE (after moving to the next or previous one, cyclically) a third
--- down the preview, with "match i/n" as the preview's label; the top of the preview when there is none.
local function match_action(how, file)
  local f = file and io.open(file, 'r')
  if not f then
    return 'change-preview-label()'
  end
  local id, index, numbers = f:read '*l', tonumber(f:read '*l' or '') or 0, f:read '*l' or ''
  f:close()
  local lines = vim.split(numbers, ' ', { trimempty = true })
  if #lines == 0 then
    return how == 'first' and 'change-preview-window(+1)+change-preview-label()' or 'change-preview-label( no match )'
  end
  if how == 'next' then
    index = index % #lines + 1
  elseif how == 'prev' then
    index = (index - 2) % #lines + 1
  end
  index = math.max(1, math.min(index, #lines))
  f = io.open(file, 'w')
  if f then
    f:write(id or '', '\n', index, '\n', numbers, '\n')
    f:close()
  end
  return ('change-preview-window(+%d/3)+change-preview-label( match %d/%d )'):format(lines[index], index, #lines)
end

local command = _G.arg[1]
local opts, rest = parse(vim.list_slice(_G.arg, 2))
if command == 'pick' then
  pick(opts, rest)
elseif command == 'match' then
  io.stdout:write(match_action(rest[1], rest[2]))
elseif command == 'scroll' then
  local port = os.getenv 'FZF_PORT'
  if port and port ~= '' and vim.fn.executable 'curl' == 1 then
    vim.system({ 'curl', '-s', '-m', '2', '-XPOST', 'localhost:' .. port, '-d', match_action('first', rest[1]) }):wait()
  end
else
  fail('unknown command: ' .. tostring(command) .. ' (expected: pick, match, scroll)')
end
