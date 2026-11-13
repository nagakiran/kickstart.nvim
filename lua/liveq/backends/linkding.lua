-- The linkding bookmark backend of liveq, run with `nvim -l`. Bookmarks are searched in the on-disk cache that the
-- shell's `linkding_search` (rcfiles .config/bash/aliases/tools.sh) also uses, so a search makes no HTTP call; the
-- cache is fetched when it is missing or unreadable, and refreshed only on request (`refresh`, ctrl-r in the picker).
--
--   nvim -l linkding.lua search -f fzf -l LIMIT -- QUERY
--   nvim -l linkding.lua show [--plain] -- ID
--   nvim -l linkding.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l linkding.lua url -- ID
--   nvim -l linkding.lua refresh
--   nvim -l linkding.lua tag -- '#add -#remove' ID...
--
-- The query language mirrors linkding's own search, evaluated locally:
--   words (all must match title, URL, description, notes or tags; -word excludes)   #tag  -#tag   !untagged  !unread
--   site:HOST   added:7d|2w|1M|1y|2026-10-01   sort:added|added_asc|title|modified
-- The last word also matches as a prefix of a tag while it is being typed (`#jun` finds #juniper).
--
-- Environment: LINKDING_URL and LINKDING_API_TOKEN (needed only to fetch or change bookmarks), LINKDING_CACHE.

local URL = os.getenv 'LINKDING_URL'
local TOKEN = os.getenv 'LINKDING_API_TOKEN'
local CACHE = os.getenv 'LINKDING_CACHE' or ((os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/linkding/bookmarks.json')
local DAY = 24 * 3600
local UNITS = { d = DAY, w = 7 * DAY, M = 30 * DAY, y = 365 * DAY }
local MAX_CANDIDATES = 100

local function out(text)
  io.stdout:write(text, '\n')
end

local function fail(message, code)
  io.stderr:write('liveq-linkding: ' .. message .. '\n')
  os.exit(code or 1)
end

local function parse(args)
  local opts, rest = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--plain' then
      opts.plain = true
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

-- -- API and cache ------------------------------------------------------------------------------------------------

local function configured()
  return URL and URL ~= '' and TOKEN and TOKEN ~= ''
end

--- curl with the token; returns the decoded JSON, or nil and an error.
local function api(method, path, body)
  if not configured() then
    return nil, 'LINKDING_URL / LINKDING_API_TOKEN are not set'
  end
  local cmd = { 'curl', '-sS', '-X', method, '-H', 'Authorization: Token ' .. TOKEN, '-H', 'Content-Type: application/json' }
  if body then
    vim.list_extend(cmd, { '--data-binary', vim.json.encode(body) })
  end
  if method == 'DELETE' then
    -- there is no JSON reply to check, so an HTTP error (404, 401) must fail curl itself
    table.insert(cmd, '-f')
  end
  table.insert(cmd, URL:gsub('/+$', '') .. '/api/' .. path)
  local result = vim.system(cmd, { text = true }):wait(60000)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or ('curl exited with ' .. result.code)
  end
  if method == 'DELETE' then
    return true
  end
  local ok, data = pcall(vim.json.decode, result.stdout or '', { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return nil, 'unexpected reply: ' .. (result.stdout or ''):sub(1, 300)
  end
  return data
end

local function write_cache(data)
  vim.fn.mkdir(vim.fs.dirname(CACHE), 'p')
  -- via a temp file, so that a failed write never clobbers a good cache
  local tmp = CACHE .. '.new'
  local file = assert(io.open(tmp, 'w'))
  file:write(vim.json.encode(data))
  file:close()
  os.rename(tmp, CACHE)
  local stamp = io.open(CACHE .. '.at', 'w')
  if stamp then
    stamp:write(os.time(), '\n')
    stamp:close()
  end
end

--- Fetches the whole collection into the cache (the format of linkding's /api/bookmarks/, as the shell's).
local function fetch()
  local data, err = api('GET', 'bookmarks/?limit=1000')
  if data and data.next and data.count then
    data, err = api('GET', 'bookmarks/?limit=' .. data.count)
  end
  if not data or not data.results then
    return nil, err or 'no results in the reply'
  end
  write_cache(data)
  return data
end

local function read_cache()
  local file = io.open(CACHE, 'r')
  if not file then
    return nil
  end
  local ok, data = pcall(vim.json.decode, file:read '*a', { luanil = { object = true, array = true } })
  file:close()
  return ok and type(data) == 'table' and data.results and data or nil
end

--- The bookmarks: the cache, or a fresh fetch when there is no usable cache.
local function bookmarks()
  local data = read_cache()
  if not data then
    local err
    data, err = fetch()
    if not data then
      return nil, err
    end
  end
  return data.results
end

local function cache_age()
  local file = io.open(CACHE .. '.at', 'r')
  local at = file and tonumber(file:read '*l')
  if file then
    file:close()
  end
  if not at then
    return 'age unknown'
  end
  local secs = os.time() - at
  if secs < 90 then
    return 'just now'
  elseif secs < 3600 then
    return math.floor(secs / 60) .. 'm old'
  elseif secs < DAY then
    return math.floor(secs / 3600) .. 'h old'
  end
  return math.floor(secs / DAY) .. 'd old'
end

local function find(id)
  for _, b in ipairs(bookmarks() or {}) do
    if tostring(b.id) == tostring(id) then
      return b
    end
  end
end

-- -- query --------------------------------------------------------------------------------------------------------

local function host_of(url)
  return ((url or ''):gsub('^%a[%w+.-]*://', ''):match '^[^/]*' or ''):gsub('^www%.', ''):lower()
end

local function title_of(b)
  return (b.title and b.title ~= '' and b.title) or (b.website_title and b.website_title ~= '' and b.website_title) or 'No Title'
end

--- The ISO date `value` (7d, 2w, 1M, 1y or a date) stands for.
local function since(value)
  local n, unit = value:match '^(%d+)([dwMy])$'
  if n then
    return os.date('!%Y-%m-%dT%H:%M:%S', os.time() - tonumber(n) * UNITS[unit])
  end
  return value:match '^%d%d%d%d%-%d%d%-?%d?%d?$' and value or nil
end

--- The query split into terms; a quoted phrase is one term.
local function terms_of(query)
  local terms = {}
  for quoted in query:gmatch '%-?"[^"]*"' do
    table.insert(terms, quoted)
  end
  query = query:gsub('%-?"[^"]*"', ' ')
  for word in query:gmatch '%S+' do
    table.insert(terms, word)
  end
  return terms
end

local function plan(query)
  local p = { words = {}, without = {}, tags = {}, without_tags = {}, sort = 'added' }
  local terms = terms_of(query)
  -- the term being typed: its tag also matches as a prefix
  local typing = query ~= '' and not query:match '%s$' and terms[#terms] or nil
  for _, t in ipairs(terms) do
    local negated = t:sub(1, 1) == '-' and #t > 1
    local body = negated and t:sub(2) or t
    local key, value = body:match '^(%a+):(.+)$'
    if body:sub(1, 1) == '#' and #body > 1 then
      table.insert(negated and p.without_tags or p.tags, { tag = body:sub(2):lower(), prefix = t == typing and not negated })
    elseif body == '!untagged' then
      p.untagged = not negated
    elseif body == '!unread' then
      p.unread = not negated
    elseif key == 'site' then
      p.site = value:lower():gsub('^www%.', '')
    elseif key == 'added' then
      p.added = since(value)
    elseif key == 'sort' then
      p.sort = value
    else
      body = body:gsub('^"(.*)"$', '%1'):lower()
      if body ~= '' then
        table.insert(negated and p.without or p.words, body)
      end
    end
  end
  return p
end

local function matches(b, p)
  local tags = {}
  for _, t in ipairs(b.tag_names or {}) do
    tags[t:lower()] = true
  end
  if p.untagged ~= nil and (next(tags) == nil) ~= p.untagged then
    return false
  end
  if p.unread ~= nil and (b.unread == true) ~= p.unread then
    return false
  end
  if p.site and not host_of(b.url):find(p.site, 1, true) then
    return false
  end
  if p.added and (b.date_added or '') < p.added then
    return false
  end
  for _, want in ipairs(p.tags) do
    local found = tags[want.tag]
    if not found and want.prefix then
      for t in pairs(tags) do
        if t:sub(1, #want.tag) == want.tag then
          found = true
          break
        end
      end
    end
    if not found then
      return false
    end
  end
  for _, t in ipairs(p.without_tags) do
    if tags[t.tag] then
      return false
    end
  end
  local haystack = table.concat({ title_of(b), b.url or '', b.description or '', b.notes or '', table.concat(b.tag_names or {}, ' ') }, '\n'):lower()
  for _, w in ipairs(p.words) do
    if not haystack:find(w, 1, true) then
      return false
    end
  end
  for _, w in ipairs(p.without) do
    if haystack:find(w, 1, true) then
      return false
    end
  end
  return true
end

local SORTS = {
  added = function(a, b)
    return (a.date_added or '') > (b.date_added or '')
  end,
  added_asc = function(a, b)
    return (a.date_added or '') < (b.date_added or '')
  end,
  modified = function(a, b)
    return (a.date_modified or '') > (b.date_modified or '')
  end,
  title = function(a, b)
    return title_of(a):lower() < title_of(b):lower()
  end,
}

-- -- commands -----------------------------------------------------------------------------------------------------

local function clean(s)
  return ((s or ''):gsub('[\t\r\n]+', ' '))
end

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local limit = tonumber(opts.l or opts.limit) or 200
  local all, err = bookmarks()
  if not all then
    out('\t\27[31m' .. clean(err) .. '\27[0m\t\t')
    return
  end
  local p = plan(query)
  local found = vim.tbl_filter(function(b)
    return matches(b, p)
  end, all)
  table.sort(found, SORTS[p.sort] or SORTS.added)
  if query == '' then
    out(
      ('\t\27[2m%d bookmarks (cache %s). Filter with words #tag -#tag !unread !untagged site: added:7d sort:  tab: complete  ctrl-r: refresh\27[0m\t\t'):format(
        #all,
        cache_age()
      )
    )
  elseif #found == 0 then
    out '\t\27[33mNo bookmarks match\27[0m\t\t'
  end
  for i = 1, math.min(#found, limit) do
    local b = found[i]
    local tags = table.concat(
      vim.tbl_map(function(t)
        return '#' .. t
      end, b.tag_names or {}),
      ' '
    )
    local display = ('\27[1m%s\27[0m  \27[36m%s\27[0m  \27[33m%s\27[0m  \27[2m%s\27[0m'):format(clean(title_of(b)), host_of(b.url), tags, clean(b.description))
    if b.unread then
      display = '\27[35m●\27[0m ' .. display
    end
    out(('%s\t%s\t%s\t%s'):format(b.id, display, clean(b.url), clean(title_of(b))))
  end
end

local function show(opts, rest)
  local id = rest[1]
  if not id or not id:match '^%d+$' then
    return
  end
  local b = find(id)
  if not b then
    out('Bookmark ' .. id .. ' is not in the cache (ctrl-r in the picker refreshes it)')
    return
  end
  local plain = opts.plain
  local bold = function(s)
    return plain and ('**' .. s .. '**') or ('\27[1m' .. s .. '\27[0m')
  end
  local lines = { (plain and '# ' or '') .. bold(title_of(b)), '', b.url }
  if b.tag_names and #b.tag_names > 0 then
    table.insert(lines, '')
    table.insert(lines, bold 'Tags:' .. ' ' .. table.concat(
      vim.tbl_map(function(t)
        return '#' .. t
      end, b.tag_names),
      ' '
    ))
  end
  table.insert(lines, bold 'Added:' .. ' ' .. (b.date_added or ''):sub(1, 10) .. (b.unread and '  (unread)' or '') .. (b.shared and '  (shared)' or ''))
  if b.description and b.description ~= '' then
    vim.list_extend(lines, { '', b.description })
  end
  if b.notes and b.notes ~= '' then
    vim.list_extend(lines, { '', plain and '## Notes' or bold 'Notes', '', b.notes })
  end
  if b.web_archive_snapshot_url and b.web_archive_snapshot_url ~= '' then
    vim.list_extend(lines, { '', bold 'Archived:' .. ' ' .. b.web_archive_snapshot_url })
  end
  out(table.concat(lines, '\n'))
end

local function url(_, rest)
  local b = rest[1] and find(rest[1])
  if b then
    out(b.url)
  end
end

local function refresh()
  local data, err = fetch()
  if not data then
    fail(err)
  end
  io.stderr:write(('Fetched %d bookmarks\n'):format(#data.results))
end

--- Changes the tags of bookmarks: `#add -#remove` (a bare word adds it too), then updates their cache rows.
local function tag(_, rest)
  local changes, ids = rest[1] or '', vim.list_slice(rest, 2)
  local add, remove = {}, {}
  for t in changes:gmatch '%S+' do
    local negated = t:sub(1, 1) == '-'
    t = t:gsub('^[+-]', ''):gsub('^#', '')
    if t ~= '' then
      table.insert(negated and remove or add, t)
    end
  end
  local data = read_cache()
  for _, id in ipairs(ids) do
    local b = find(id)
    if not b then
      fail('bookmark ' .. id .. ' is not in the cache')
    end
    local tags, seen = {}, {}
    for _, t in ipairs(vim.list_extend(vim.deepcopy(b.tag_names or {}), add)) do
      if not seen[t] and not vim.tbl_contains(remove, t) then
        seen[t] = true
        table.insert(tags, t)
      end
    end
    local updated, err = api('PATCH', 'bookmarks/' .. id .. '/', { tag_names = tags })
    if not updated then
      fail(err)
    end
    for i, row in ipairs(data and data.results or {}) do
      if row.id == updated.id then
        data.results[i] = updated
      end
    end
  end
  if data then
    write_cache(data)
  end
end

--- Deletes bookmarks on the server, then drops their rows from the cache (else they would come back with it).
local function delete(_, rest)
  local data = read_cache()
  for _, id in ipairs(rest) do
    local ok, err = api('DELETE', 'bookmarks/' .. id .. '/')
    if not ok then
      fail('deleting ' .. id .. ': ' .. err)
    end
    if data then
      data.results = vim.tbl_filter(function(row)
        return tostring(row.id) ~= tostring(id)
      end, data.results)
      write_cache(data)
    end
  end
end

-- -- complete -----------------------------------------------------------------------------------------------------

local PREFIXES = {
  { '#', 'tag' },
  { '-#', 'without the tag' },
  { '!unread', 'unread bookmarks' },
  { '!untagged', 'bookmarks without tags' },
  { 'site:', 'host of the URL' },
  { 'added:', 'added since: 7d, 2w, 1M, 1y or a date' },
  { 'sort:', 'added, added_asc, modified, title' },
}

--- Values with how often they occur, most frequent first, keeping those that start with `typed`.
local function by_frequency(counts, typed)
  local list = {}
  for v, n in pairs(counts) do
    if typed == '' or v:lower():sub(1, #typed) == typed:lower() then
      table.insert(list, { v, n })
    end
  end
  table.sort(list, function(a, b)
    return a[2] ~= b[2] and a[2] > b[2] or a[1] < b[1]
  end)
  return vim.list_slice(list, 1, MAX_CANDIDATES)
end

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
  local before = vim.fn.strcharpart(text, 0, cursor)
  local start = cursor
  while start > 0 and not vim.fn.strcharpart(before, start - 1, 1):match '%s' do
    start = start - 1
  end
  local finish, length = cursor, vim.fn.strchars(text)
  while finish < length and not vim.fn.strcharpart(text, finish, 1):match '%s' do
    finish = finish + 1
  end
  local term = vim.fn.strcharpart(text, start, cursor - start)

  local context, candidates = 'field', {}
  local add = function(insert, kind, detail)
    table.insert(candidates, { display = insert, insert = insert .. ' ', cursor_offset = vim.fn.strchars(insert) + 1, kind = kind, detail = detail or '' })
  end
  local sign, tag_typed = term:match '^(%-?)#(.*)$'
  local key, value = term:match '^(%a+):(.*)$'
  if sign then
    context = 'value'
    local counts = {}
    for _, b in ipairs(bookmarks() or {}) do
      for _, t in ipairs(b.tag_names or {}) do
        counts[t] = (counts[t] or 0) + 1
      end
    end
    for _, v in ipairs(by_frequency(counts, tag_typed)) do
      add(sign .. '#' .. v[1], 'value', v[2] .. ' bookmarks')
    end
  elseif key == 'site' then
    context = 'value'
    local counts = {}
    for _, b in ipairs(bookmarks() or {}) do
      local h = host_of(b.url)
      counts[h] = (counts[h] or 0) + 1
    end
    for _, v in ipairs(by_frequency(counts, value)) do
      add('site:' .. v[1], 'value', v[2] .. ' bookmarks')
    end
  elseif key == 'added' or key == 'sort' then
    context = 'value'
    local values = key == 'added' and { '1d', '7d', '2w', '1M', '3M', '6M', '1y' } or { 'added', 'added_asc', 'modified', 'title' }
    for _, v in ipairs(values) do
      if v:sub(1, #value) == value then
        add(key .. ':' .. v, 'value')
      end
    end
  elseif term == '' or term:match '^[-!%a]' then
    for _, p in ipairs(PREFIXES) do
      if p[1]:sub(1, #term) == term and p[1] ~= term then
        local insert = p[1]
        -- a prefix that takes a value leaves the cursor right after it
        local open = insert:match '[#:]$'
        table.insert(candidates, {
          display = insert,
          insert = open and insert or (insert .. ' '),
          cursor_offset = vim.fn.strchars(insert) + (open and 0 or 1),
          kind = open and 'field' or 'keyword',
          detail = p[2],
        })
      end
    end
  end
  out(vim.json.encode { context = context, prefix = term, replace_start = start, replace_end = finish, candidates = candidates })
end

local commands = { search = search, show = show, complete = complete, url = url, refresh = refresh, tag = tag, delete = delete }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
