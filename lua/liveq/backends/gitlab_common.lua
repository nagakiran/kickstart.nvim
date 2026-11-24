-- Helpers shared by liveq's GitLab backends (gitlab.lua: merge requests, gitlab_activity.lua: the activity feed), each
-- run with `nvim -l`; they talk to GitLab through `glab api`, so they use glab's login and host. Loaded with dofile:
--
--   local C = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'gitlab_common.lua'))
--
-- Environment: LIVEQ_GITLAB_HOST (default: glab's host).

local C = {}

C.DAY = 24 * 3600
C.CACHE_DIR = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/liveq/gitlab'
C.CONFIG_DIR = (os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')) .. '/liveq'
C.name = 'liveq-gitlab'

local HOST = os.getenv 'LIVEQ_GITLAB_HOST'

function C.out(text)
  io.stdout:write(text, '\n')
end

function C.fail(message, code)
  io.stderr:write(C.name .. ': ' .. message .. '\n')
  os.exit(code or 1)
end

function C.host()
  if not HOST or HOST == '' then
    local result = vim.system({ 'glab', 'config', 'get', 'host' }, { text = true }):wait()
    HOST = vim.trim(result.stdout or '')
    if HOST == '' then
      HOST = 'gitlab.com'
    end
  end
  return HOST
end

function C.encode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

-- -- cache --------------------------------------------------------------------------------------------------------

function C.cache_path(key)
  return C.CACHE_DIR .. '/' .. C.host() .. '-' .. key:gsub('[^%w%-_.]', '_') .. '.json'
end

function C.read_json(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local ok, data = pcall(vim.json.decode, file:read '*a', { luanil = { object = true, array = true } })
  file:close()
  return ok and data or nil
end

--- Writes DATA as JSON to PATH through a temporary file, so that a reader never sees half of it.
function C.write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.' .. vim.uv.os_getpid()
  local file = io.open(tmp, 'w')
  if file then
    file:write(vim.json.encode(data))
    file:close()
    os.rename(tmp, path)
  end
end

function C.cache_get(key, ttl)
  local path = C.cache_path(key)
  local stat = vim.uv.fs_stat(path)
  if not stat or os.time() - stat.mtime.sec > ttl then
    return nil
  end
  return C.read_json(path)
end

function C.cache_set(key, data)
  C.write_json(C.cache_path(key), data)
end

-- -- API ----------------------------------------------------------------------------------------------------------

--- Starts `glab api PATH`; returns a function that waits for it and returns the decoded JSON, or nil and an error.
function C.api_async(path)
  local job = vim.system({ 'glab', 'api', '--hostname', C.host(), path }, { text = true })
  return function()
    local result = job:wait(60000)
    if result.code ~= 0 then
      local message = vim.trim((result.stderr ~= '' and result.stderr) or result.stdout or '')
      return nil, message ~= '' and message or ('glab exited with ' .. result.code)
    end
    local ok, data = pcall(vim.json.decode, result.stdout or 'null', { luanil = { object = true, array = true } })
    if not ok then
      return nil, 'invalid JSON from glab'
    end
    return data
  end
end

function C.api(path)
  return C.api_async(path)()
end

function C.me()
  local cached = C.cache_get('me', 30 * C.DAY)
  if cached and cached.username then
    return cached.username
  end
  local user = C.api 'user'
  if user and user.username then
    C.cache_set('me', { username = user.username })
    return user.username
  end
  return nil
end

-- -- query --------------------------------------------------------------------------------------------------------

--- Splits a query into terms, keeping quoted values together: `label:"needs review" fix` -> two terms.
function C.terms_of(query)
  local terms, current, quoted = {}, {}, false
  for _, ch in ipairs(vim.split(query, '')) do
    if ch == '"' then
      quoted = not quoted
    elseif ch:match '%s' and not quoted then
      if #current > 0 then
        table.insert(terms, table.concat(current))
        current = {}
      end
    else
      table.insert(current, ch)
    end
  end
  if #current > 0 then
    table.insert(terms, table.concat(current))
  end
  return terms
end

--- The seconds that a relative time like 7d, 2w, 1M or 1y stands for, or nil.
function C.span(value)
  local n, unit = value:match '^(%d+)([hdwMy])$'
  if not n then
    return nil
  end
  return ({ h = 3600, d = C.DAY, w = 7 * C.DAY, M = 30 * C.DAY, y = 365 * C.DAY })[unit] * tonumber(n)
end

--- A time for the API: 7d -> the UTC time 7 days ago; a date stays as typed.
function C.since(value)
  local seconds = C.span(value)
  if not seconds then
    return value
  end
  return os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - seconds)
end

function C.user(value)
  if value == '@me' or value == 'me' then
    return C.me() or value
  end
  return (value:gsub('^@', ''))
end

-- -- output -------------------------------------------------------------------------------------------------------

function C.parse(args)
  local opts, rest = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--plain' or a == '--tree' or a == '--header' then
      opts[(a:gsub('^%-+', ''))] = true
      i = i + 1
    elseif a:match '^%-' and args[i + 1] then
      opts[(a:gsub('^%-+', ''))] = args[i + 1]
      i = i + 2
    else
      table.insert(rest, a)
      i = i + 1
    end
  end
  return opts, rest
end

function C.truncate(s, width)
  s = (s or ''):gsub('%s+', ' ')
  local n = vim.fn.strchars(s)
  if n > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. '…'
  end
  return s .. string.rep(' ', width - n)
end

-- -- complete -----------------------------------------------------------------------------------------------------

function C.candidate(display, insert, kind, detail)
  return { display = display, insert = insert, cursor_offset = vim.fn.strchars(insert), kind = kind, detail = detail or '' }
end

function C.quote(value)
  return value:find '[%s"]' and ('"' .. value:gsub('"', '') .. '"') or value
end

function C.matching(values, typed, max)
  typed = typed:lower()
  local result = {}
  for _, v in ipairs(values) do
    if typed == '' or v:lower():find(typed, 1, true) then
      table.insert(result, v)
      if #result >= (max or 100) then
        break
      end
    end
  end
  return result
end

--- The term around CURSOR in TEXT (quoted values kept together): its start and end offsets, and the part before the
--- cursor.
function C.term_at(text, cursor)
  local before = vim.fn.strcharpart(text, 0, cursor)
  local start, in_quote = cursor, false
  for i = cursor, 1, -1 do
    local ch = vim.fn.strcharpart(before, i - 1, 1)
    if ch == '"' then
      in_quote = not in_quote
    elseif not in_quote and ch:match '%s' then
      break
    end
    start = i - 1
  end
  local finish, length = cursor, vim.fn.strchars(text)
  while finish < length and not vim.fn.strcharpart(text, finish, 1):match '%s' do
    finish = finish + 1
  end
  return start, finish, vim.fn.strcharpart(text, start, cursor - start)
end

--- Users for a `author:`-like value: @me, then the members of PROJECT whose name or username has TYPED.
function C.users(project, typed)
  local result = { { '@me', 'you' } }
  if typed ~= '' and not ('@me'):find(typed, 1, true) then
    result = {}
  end
  local members = C.api(('projects/%s/members/all?per_page=50&query=%s'):format(C.encode(project), C.encode((typed:gsub('^@', ''))))) or {}
  for _, m in ipairs(members) do
    if m.username and m.state ~= 'blocked' then
      table.insert(result, { m.username, m.name })
    end
  end
  return result
end

--- Projects you are a member of whose path has TYPED; EXTRA (a list of { value, detail }) first when nothing is typed.
function C.projects(typed, extra)
  if typed == '' then
    return extra or {}
  end
  local result = {}
  for _, p in ipairs(C.api(('projects?membership=true&simple=true&per_page=30&search=%s'):format(C.encode(typed))) or {}) do
    table.insert(result, { p.path_with_namespace })
  end
  return result
end

-- -- saved queries ------------------------------------------------------------------------------------------------

function C.read_saved(file_path)
  local entries = {}
  local file = io.open(file_path, 'r')
  if file then
    for line in file:lines() do
      local label, query = line:match '^([^\t]+)\t(.+)$'
      if label then
        table.insert(entries, { label = label, query = query })
      end
    end
    file:close()
  end
  return entries
end

--- `saved -f tsv`: label, query, key and origin of each saved query of FILE_PATH.
function C.saved(file_path)
  for _, e in ipairs(C.read_saved(file_path)) do
    C.out(('%s\t%s\t%s\tsaved'):format(e.label, e.query, e.label))
  end
end

--- `save [--label L] -- QUERY` into FILE_PATH; the label is asked for on the terminal when not given.
function C.save(file_path, opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  if query == '' then
    C.fail 'a query is required'
  end
  local label = opts.label or opts.l
  if not label then
    io.stderr:write('Saving: ' .. query .. '\nLabel: ')
    local tty = io.open('/dev/tty', 'r')
    label = tty and tty:read '*l' or nil
    if tty then
      tty:close()
    end
  end
  label = label and vim.trim((label:gsub('\t', ' '))) or ''
  if label == '' then
    C.fail 'a label is required'
  end
  local entries = vim.tbl_filter(function(e)
    return e.label ~= label
  end, C.read_saved(file_path))
  table.insert(entries, { label = label, query = query })
  vim.fn.mkdir(vim.fs.dirname(file_path), 'p')
  local file = assert(io.open(file_path, 'w'))
  for _, e in ipairs(entries) do
    file:write(e.label, '\t', e.query, '\n')
  end
  file:close()
  io.stderr:write('Saved: ' .. label .. '\n')
end

return C
