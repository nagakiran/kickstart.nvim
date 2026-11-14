-- The command-line helper of liveq, run with `nvim -l` (no plugins, no user config; starts in ~40ms).
--
--   nvim -l cli.lua pick --cmd '<backend>' [--cursor N] -- QUERY
--
-- Completes QUERY with a picker on the terminal (fzf) and prints the new query. It only needs the backend's
-- `complete -f json` command, so a source does not have to implement a picker of its own; used by the TAB of `lq`
-- (shell) and of the fzf-lua picker. Exits with status 1, printing nothing, when nothing was picked.
--
--   nvim -l cli.lua lines --cmd '<backend>' --start S --end E -- QUERY TERM   candidates for fzf's reload (internal)
--   nvim -l cli.lua match {first|next|prev} FILE     prints the fzf action that scrolls the preview to a match
--   nvim -l cli.lua scroll FILE                      sends `match first` to the fzf of $FZF_PORT (with curl)
--
-- FILE is the one a backend's `show --match` wrote ($LIVEQ_MATCH_FILE): the item's id, the index of the current match,
-- and the line numbers of the matches (one followed by `t` goes to the top of the preview, e.g. where the message of
-- a row starts, instead of a third down). `scroll` runs in the background after the preview is printed, since fzf only
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
    elseif a == '--cmd' or a == '--cursor' or a == '--start' or a == '--end' then
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

--- Runs the backend's `complete -f json` on TEXT (cursor at CURSOR, the end when nil); nil and a message on failure.
local function complete(backend, text, cursor)
  local complete_cmd = ('%s complete -f json %s-- %s'):format(backend, cursor and ('-c ' .. cursor .. ' ') or '', vim.fn.shellescape(text))
  local result = vim.system({ 'sh', '-c', complete_cmd }, { text = true }):wait(30000)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or '')
  end
  local ok, data = pcall(vim.json.decode, result.stdout or '')
  if not ok or type(data) ~= 'table' then
    return nil, 'invalid output of the complete command'
  end
  data.candidates = data.candidates or {}
  return data
end

--- The lines given to fzf: `insert<TAB>cursor_offset<TAB>display<TAB>detail`, of which fzf shows only the last two.
local function fzf_lines(candidates)
  local width = 0
  for _, c in ipairs(candidates) do
    width = math.min(math.max(width, vim.fn.strchars(c.display)), 40)
  end
  local lines = {}
  for _, c in ipairs(candidates) do
    local detail = vim.trim((c.kind or '') .. ' ' .. (c.detail or ''))
    local insert = (c.insert or c.display):gsub('[\t\n]', ' ')
    table.insert(lines, ('%s\t%s\t%s\t\27[2m%s\27[0m'):format(insert, c.cursor_offset or '', pad(c.display, width), detail))
  end
  return lines
end

--- The text of QUERY with its characters START..FINISH replaced by TERM, and the position at the end of TERM.
local function with_term(query, start, finish, term)
  local before = vim.fn.strcharpart(query, 0, start)
  return before .. term .. vim.fn.strcharpart(query, finish), start + vim.fn.strchars(term)
end

--- `lines`: the candidates for QUERY with its characters START..END replaced by TERM, as lines for fzf. It is the
--- reload command of the picker of values, so that they are asked for again as the term is edited in fzf (a backend
--- returns only the first page of what matches, so filtering that page in fzf misses the rest).
local function lines(opts, rest)
  local backend = opts.cmd or fail '--cmd is required'
  local text, cursor = with_term(rest[1] or '', tonumber(opts.start) or 0, tonumber(opts['end']) or 0, rest[2] or '')
  local data = complete(backend, text, cursor)
  if data then
    io.stdout:write(table.concat(fzf_lines(data.candidates), '\n'), '\n')
  end
end

local function pick(opts, rest)
  local backend = opts.cmd or fail '--cmd is required'
  local query = rest[1] or ''
  local cursor = tonumber(opts.cursor)
  local data, err = complete(backend, query, cursor)
  if not data then
    fail(err)
  end
  local is_value = data.context == 'value'
  local candidates = data.candidates
  if #candidates == 0 and not is_value then
    fail()
  end

  local fzf_cmd = {
    'fzf',
    '--ansi',
    '--delimiter=\t',
    '--with-nth=3..',
    '--nth=1,2',
    '--height=40%',
    '--reverse',
    '--no-multi',
    '--print-query',
    '--prompt=' .. (data.context or 'pick') .. '> ',
  }
  if is_value then
    -- the query of fzf is the whole term (e.g. `target:feat`), and each edit asks the backend again for that term
    local start, finish = data.replace_start or 0, data.replace_end or 0
    local term = vim.fn.strcharpart(query, start, finish - start)
    local reload = ('%s -l %s lines --cmd %s --start %d --end %d -- %s {q}'):format(
      vim.fn.shellescape(vim.v.progpath),
      vim.fn.shellescape(here),
      vim.fn.shellescape(backend),
      start,
      finish,
      vim.fn.shellescape(query)
    )
    vim.list_extend(fzf_cmd, { '--disabled', '--query=' .. term, '--bind=change:reload:' .. reload })
  else
    vim.list_extend(fzf_cmd, { '--select-1', '--exit-0' })
  end
  local extra = os.getenv 'LIVEQ_FZF_OPTS'
  if extra and extra ~= '' then
    vim.list_extend(fzf_cmd, vim.split(extra, '%s+', { trimempty = true }))
  end
  -- fzf draws on /dev/tty by itself; its stdin is the list and its stdout the choice
  local picked = vim.system(fzf_cmd, { stdin = table.concat(fzf_lines(candidates), '\n'), text = true }):wait()
  if picked.code ~= 0 and picked.code ~= 1 then
    fail()
  end
  local out = vim.split(picked.stdout or '', '\n', { plain = true })
  local typed, selection = vim.trim(out[1] or ''), out[2] or ''

  local insert, cursor_offset
  if vim.trim(selection) ~= '' then
    local fields = vim.split(selection, '\t', { plain = true })
    insert, cursor_offset = fields[1], tonumber(fields[2] or '')
  elseif is_value and typed ~= '' then
    -- a value that the backend does not suggest is taken as typed (the query of fzf is the whole term)
    insert, cursor_offset = typed, vim.fn.strchars(typed)
  end
  if not insert or insert == '' then
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
  local line, top = lines[index]:match '^(%d+)(t?)$'
  return ('change-preview-window(+%s%s)+change-preview-label( match %d/%d )'):format(line, top == 't' and '' or '/3', index, #lines)
end

local command = _G.arg[1]
local opts, rest = parse(vim.list_slice(_G.arg, 2))
if command == 'pick' then
  pick(opts, rest)
elseif command == 'lines' then
  lines(opts, rest)
elseif command == 'match' then
  io.stdout:write(match_action(rest[1], rest[2]))
elseif command == 'scroll' then
  local port = os.getenv 'FZF_PORT'
  if port and port ~= '' and vim.fn.executable 'curl' == 1 then
    vim.system({ 'curl', '-s', '-m', '2', '-XPOST', 'localhost:' .. port, '-d', match_action('first', rest[1]) }):wait()
  end
else
  fail('unknown command: ' .. tostring(command) .. ' (expected: pick, lines, match, scroll)')
end
