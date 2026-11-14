-- The GitLab merge-request backend of liveq, run with `nvim -l`; it talks to GitLab through `glab api`, so it uses
-- glab's login and host.
--
--   nvim -l gitlab.lua search -f fzf -l LIMIT -- QUERY
--   nvim -l gitlab.lua show [--plain] -- PROJECT!IID           (or !IID, in the default project)
--   nvim -l gitlab.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l gitlab.lua url -- PROJECT!IID
--   nvim -l gitlab.lua saved -f tsv / save [--label NAME] -- QUERY
--
-- The query language mirrors the search bar of GitLab:
--   state:opened|merged|closed|locked|all (default opened)   author:@me   assignee:NAME   reviewer:NAME
--   label:NAME  -label:NAME   milestone:NAME   project:PATH|all   branch:SOURCE   target:TARGET   draft:yes|no
--   created:7d  updated:2w (or a date: updated:2026-10-01)    sort:updated|created|updated_asc|created_asc
--   any other word searches the title and the description.
--
-- Environment: LIVEQ_GITLAB_HOST (default: glab's host), LIVEQ_GITLAB_PROJECT (default project: sd/security_director).

local PREFIXES = {
  { 'state:', 'opened, merged, closed, locked, all' },
  { 'author:', 'who opened the MR (@me for you)' },
  { 'assignee:', 'assigned user' },
  { 'reviewer:', 'reviewer' },
  { 'label:', 'label' },
  { '-label:', 'without the label' },
  { 'milestone:', 'milestone' },
  { 'project:', 'project path, or all' },
  { 'branch:', 'source branch' },
  { 'target:', 'target branch' },
  { 'draft:', 'yes or no' },
  { 'created:', 'created since: 7d, 2w, 1M or a date' },
  { 'updated:', 'updated since: 7d, 2w, 1M or a date' },
  { 'sort:', 'updated, created, updated_asc, created_asc' },
}
local STATIC = {
  state = { 'opened', 'merged', 'closed', 'locked', 'all' },
  draft = { 'yes', 'no' },
  sort = { 'updated', 'created', 'updated_asc', 'created_asc' },
  created = { '1d', '2d', '7d', '2w', '1M', '3M', '6M', '1y' },
  updated = { '1d', '2d', '7d', '2w', '1M', '3M', '6M', '1y' },
}
local DAY = 24 * 3600
local MAX_CANDIDATES = 100

local HOST = os.getenv 'LIVEQ_GITLAB_HOST'
local DEFAULT_PROJECT = os.getenv 'LIVEQ_GITLAB_PROJECT' or 'sd/security_director'
local CACHE_DIR = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/liveq/gitlab'
local SAVED_FILE = (os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')) .. '/liveq/gitlab-saved.tsv'

local function out(text)
  io.stdout:write(text, '\n')
end

local function fail(message, code)
  io.stderr:write('liveq-gitlab: ' .. message .. '\n')
  os.exit(code or 1)
end

local function host()
  if not HOST or HOST == '' then
    local result = vim.system({ 'glab', 'config', 'get', 'host' }, { text = true }):wait()
    HOST = vim.trim(result.stdout or '')
    if HOST == '' then
      HOST = 'gitlab.com'
    end
  end
  return HOST
end

local function encode(s)
  return (s:gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

-- -- cache --------------------------------------------------------------------------------------------------------

local function cache_path(key)
  return CACHE_DIR .. '/' .. host() .. '-' .. key:gsub('[^%w%-_.]', '_') .. '.json'
end

local function cache_get(key, ttl)
  local path = cache_path(key)
  local stat = vim.uv.fs_stat(path)
  if not stat or os.time() - stat.mtime.sec > ttl then
    return nil
  end
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local ok, data = pcall(vim.json.decode, file:read '*a', { luanil = { object = true, array = true } })
  file:close()
  return ok and data or nil
end

local function cache_set(key, data)
  vim.fn.mkdir(CACHE_DIR, 'p')
  local file = io.open(cache_path(key), 'w')
  if file then
    file:write(vim.json.encode(data))
    file:close()
  end
end

-- -- API ----------------------------------------------------------------------------------------------------------

--- Starts `glab api PATH`; returns a function that waits for it and returns the decoded JSON, or nil and an error.
local function api_async(path)
  local job = vim.system({ 'glab', 'api', '--hostname', host(), path }, { text = true })
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

local function api(path)
  return api_async(path)()
end

local function me()
  local cached = cache_get('me', 30 * DAY)
  if cached and cached.username then
    return cached.username
  end
  local user = api 'user'
  if user and user.username then
    cache_set('me', { username = user.username })
    return user.username
  end
  return nil
end

-- -- query --------------------------------------------------------------------------------------------------------

--- Splits a query into terms, keeping quoted values together: `label:"needs review" fix` -> two terms.
local function terms_of(query)
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

local function since(value)
  local n, unit = value:match '^(%d+)([dwMy])$'
  if not n then
    return value -- a date, as typed
  end
  local seconds = ({ d = DAY, w = 7 * DAY, M = 30 * DAY, y = 365 * DAY })[unit] * tonumber(n)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - seconds)
end

local function user(value)
  if value == '@me' or value == 'me' then
    return me() or value
  end
  return (value:gsub('^@', ''))
end

--- Turns a query into the API calls of a search: a list of paths (several when the results are a union).
local function plan(query, limit)
  local params, words = {}, {}
  local project = DEFAULT_PROJECT
  local labels, not_labels = {}, {}
  local state, people = 'opened', false
  for _, term in ipairs(terms_of(query)) do
    local key, value = term:match '^(%-?[%w_]+):(.*)$'
    if key and value ~= '' then
      key = key:lower()
      if STATIC[key] and key ~= 'created' and key ~= 'updated' and not vim.tbl_contains(STATIC[key], value) then
        return nil, nil, ('%s: must be one of %s'):format(key, table.concat(STATIC[key], ', '))
      elseif key == 'state' then
        state = value
      elseif key == 'author' then
        params.author_username, people = user(value), true
      elseif key == 'assignee' then
        params.assignee_username, people = user(value), true
      elseif key == 'reviewer' then
        params.reviewer_username, people = user(value), true
      elseif key == 'label' then
        table.insert(labels, value)
      elseif key == '-label' then
        table.insert(not_labels, value)
      elseif key == 'milestone' then
        params.milestone = value
      elseif key == 'project' then
        project = value
      elseif key == 'branch' then
        params.source_branch = value
      elseif key == 'target' then
        params.target_branch = value
      elseif key == 'draft' then
        params.wip = (value == 'yes' or value == 'true') and 'yes' or 'no'
      elseif key == 'created' then
        params.created_after = since(value)
      elseif key == 'updated' then
        params.updated_after = since(value)
      elseif key == 'sort' then
        params.order_by = value:match '^created' and 'created_at' or 'updated_at'
        params.sort = value:match '_asc$' and 'asc' or 'desc'
      else
        table.insert(words, term)
      end
    else
      table.insert(words, term)
    end
  end
  if state ~= 'all' then
    params.state = state
  end
  if #labels > 0 then
    params.labels = table.concat(labels, ',')
  end
  if #not_labels > 0 then
    params['not[labels]'] = table.concat(not_labels, ',')
  end
  if #words > 0 then
    params.search = table.concat(words, ' ')
  end
  params.order_by = params.order_by or 'updated_at'
  params.sort = params.sort or 'desc'
  params.per_page = tostring(math.min(limit, 100))

  local base
  if project == 'all' then
    base = 'merge_requests'
    params.scope = 'all'
  else
    base = 'projects/' .. encode(project) .. '/merge_requests'
  end
  local function path(extra)
    local query_string = {}
    for k, v in pairs(vim.tbl_extend('force', params, extra or {})) do
      table.insert(query_string, encode(k) .. '=' .. encode(v))
    end
    table.sort(query_string)
    return base .. '?' .. table.concat(query_string, '&')
  end
  if project == 'all' and not people and not params.search then
    -- everything on the instance is too much: the MRs you authored or review
    local username = me() or ''
    return { path { author_username = username }, path { reviewer_username = username } }, project
  end
  return { path() }, project
end

-- -- search -------------------------------------------------------------------------------------------------------

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

local function truncate(s, width)
  s = (s or ''):gsub('%s+', ' ')
  local n = vim.fn.strchars(s)
  if n > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. '…'
  end
  return s .. string.rep(' ', width - n)
end

local STATE_COLOUR = { opened = '32', merged = '35', closed = '31', locked = '33' }

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local fzf = (opts.f or opts.format) == 'fzf'
  local limit = tonumber(opts.l or opts.limit) or 100
  local paths, project, invalid = plan(query, limit)
  if not paths then
    if fzf then
      out('\t\27[31m' .. invalid .. '\27[0m\t\t')
      return
    end
    fail(invalid)
  end
  local waits = vim.tbl_map(api_async, paths)
  local seen, mrs = {}, {}
  for _, wait in ipairs(waits) do
    local data, err = wait()
    if not data then
      if fzf then
        out('\t\27[31m' .. err:gsub('\n', ' ') .. '\27[0m\t\t')
        return
      end
      fail(err)
    end
    for _, mr in ipairs(data) do
      local id = mr.references and mr.references.full or ((mr.web_url or ''):match '://[^/]+/(.-)/%-/merge_requests' .. '!' .. mr.iid)
      if not seen[id] then
        seen[id] = true
        mr._id = id
        table.insert(mrs, mr)
      end
    end
  end
  table.sort(mrs, function(a, b)
    return (a.updated_at or '') > (b.updated_at or '')
  end)
  if fzf and query == '' then
    out(('\t\27[2mOpen MRs of %s. Filter with author:@me reviewer:@me label: state: updated:7d project:all …  tab: complete\27[0m\t\t'):format(project))
  end
  if #mrs == 0 and fzf then
    out '\t\27[2mNo merge requests match the query\27[0m\t\t'
  end
  for i, mr in ipairs(mrs) do
    if i > limit then
      break
    end
    local title = (mr.title or ''):gsub('[\t\n]', ' ')
    if fzf then
      local where = project == 'all' and ('\27[2m' .. truncate((mr._id:gsub('!%d+$', '')):match '[^/]+$', 18) .. '\27[0m ') or ''
      local labels = #(mr.labels or {}) > 0 and (' \27[36m' .. table.concat(mr.labels, ' ') .. '\27[0m') or ''
      out(
        ('%s\t%s\27[35m!%-6s\27[0m \27[%sm%-6s\27[0m \27[33m%s\27[0m \27[2m%s\27[0m %s%s%s\t%s\t%s'):format(
          mr._id,
          where,
          mr.iid,
          STATE_COLOUR[mr.state] or '0',
          mr.state,
          truncate(mr.author and mr.author.name or '', 18),
          (mr.updated_at or ''):sub(1, 10),
          mr.draft and '\27[2m[draft]\27[0m ' or '',
          title,
          labels,
          mr.web_url or '',
          title
        )
      )
    else
      out(('%s\t%s\t%s\t%s\t%s'):format(mr._id, mr.state, mr.author and mr.author.username or '', title, mr.web_url or ''))
    end
  end
end

-- -- show ---------------------------------------------------------------------------------------------------------

local function split_id(id)
  local project, iid = (id or ''):match '^([%w._/-]*)!(%d+)$'
  if not iid then
    return nil
  end
  return project ~= '' and project or DEFAULT_PROJECT, iid
end

local function show(opts, rest)
  local project, iid = split_id(rest[1])
  if not iid then
    return -- e.g. a hint line of fzf
  end
  local key = 'mr-' .. project .. '-' .. iid
  local mr = cache_get(key, 120)
  if not mr then
    local err
    mr, err = api(('projects/%s/merge_requests/%s'):format(encode(project), iid))
    if not mr then
      fail(err)
    end
    cache_set(key, mr)
  end
  local plain = opts.plain
  local bold, dim, reset = '\27[1m', '\27[2m', '\27[0m'
  if plain then
    bold, dim, reset = '', '', ''
  end
  local names = function(list)
    return table.concat(
      vim.tbl_map(function(u)
        return u.name or u.username
      end, list or {}),
      ', '
    )
  end
  out(('%s%s%s!%s  %s'):format(plain and '# ' or '', bold, project, iid, mr.title or '') .. reset)
  local pipeline = mr.head_pipeline or mr.pipeline
  local rows = {
    { 'State', (mr.state or '') .. (mr.draft and ' (draft)' or '') },
    { 'Merge', mr.detailed_merge_status or mr.merge_status or '' },
    { 'Branches', ('%s → %s'):format(mr.source_branch or '', mr.target_branch or '') },
    { 'Author', mr.author and mr.author.name or '' },
    { 'Reviewers', names(mr.reviewers) },
    { 'Assignees', names(mr.assignees) },
    { 'Labels', table.concat(mr.labels or {}, ', ') },
    { 'Milestone', mr.milestone and mr.milestone.title or '' },
    { 'Pipeline', pipeline and (pipeline.status or '') or '' },
    { 'Changes', mr.changes_count and (mr.changes_count .. ' files') or '' },
    { 'Comments', mr.user_notes_count and tostring(mr.user_notes_count) or '' },
    { 'Created', (mr.created_at or ''):sub(1, 16):gsub('T', ' ') },
    { 'Updated', (mr.updated_at or ''):sub(1, 16):gsub('T', ' ') },
    { 'URL', mr.web_url or '' },
  }
  for _, row in ipairs(rows) do
    if row[2] ~= '' then
      out(plain and ('- **%s**: %s'):format(row[1], row[2]) or ('%s%-10s%s %s'):format(dim, row[1], reset, row[2]))
    end
  end
  local description = vim.trim(mr.description or '')
  if description ~= '' then
    out ''
    out((plain and '## ' or '') .. bold .. 'Description' .. reset)
    out(description)
  end
end

local function url(_, rest)
  local project, iid = split_id(rest[1])
  if iid then
    out(('https://%s/%s/-/merge_requests/%s'):format(host(), project, iid))
  end
end

-- -- complete -----------------------------------------------------------------------------------------------------

local function candidate(display, insert, kind, detail)
  return { display = display, insert = insert, cursor_offset = vim.fn.strchars(insert), kind = kind, detail = detail or '' }
end

local function quote(value)
  return value:find '[%s"]' and ('"' .. value:gsub('"', '') .. '"') or value
end

local function cached_list(key, path, field, ttl)
  local list = cache_get(key, ttl)
  if list then
    return list
  end
  local data = api(path)
  if type(data) ~= 'table' then
    return {}
  end
  list = {}
  for _, item in ipairs(data) do
    if item[field] then
      table.insert(list, item[field])
    end
  end
  cache_set(key, list)
  return list
end

local function matching(values, typed)
  typed = typed:lower()
  local result = {}
  for _, v in ipairs(values) do
    if typed == '' or v:lower():find(typed, 1, true) then
      table.insert(result, v)
      if #result >= MAX_CANDIDATES then
        break
      end
    end
  end
  return result
end

local function values_for(key, typed, project)
  local p = encode(project == 'all' and DEFAULT_PROJECT or project)
  if STATIC[key] then
    return vim.tbl_map(function(v)
      return { v }
    end, matching(STATIC[key], typed))
  elseif key == 'author' or key == 'assignee' or key == 'reviewer' then
    local result = { { '@me', 'you' } }
    if typed ~= '' and not ('@me'):find(typed, 1, true) then
      result = {}
    end
    local members = api(('projects/%s/members/all?per_page=50&query=%s'):format(p, encode((typed:gsub('^@', ''))))) or {}
    for _, m in ipairs(members) do
      if m.username and m.state ~= 'blocked' then
        table.insert(result, { m.username, m.name })
      end
    end
    return result
  elseif key == 'label' or key == '-label' then
    local labels = cached_list('labels-' .. p, ('projects/%s/labels?per_page=100&include_ancestor_groups=true'):format(p), 'name', DAY)
    return vim.tbl_map(function(v)
      return { v }
    end, matching(labels, typed))
  elseif key == 'milestone' then
    local milestones = cached_list('milestones-' .. p, ('projects/%s/milestones?state=active&per_page=100'):format(p), 'title', DAY)
    return vim.tbl_map(function(v)
      return { v }
    end, matching(milestones, typed))
  elseif key == 'branch' or key == 'target' then
    local branches = api(('projects/%s/repository/branches?per_page=100&sort=updated_desc&search=%s'):format(p, encode(typed))) or {}
    return vim.tbl_map(function(b)
      return { b.name }
    end, branches)
  elseif key == 'project' then
    local result = { { 'all', 'every project' }, { DEFAULT_PROJECT, 'default' } }
    if typed ~= '' then
      result = {}
      local projects = api(('projects?membership=true&simple=true&per_page=30&search=%s'):format(encode(typed))) or {}
      for _, project_data in ipairs(projects) do
        table.insert(result, { project_data.path_with_namespace })
      end
    end
    return result
  end
  return {}
end

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
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
  local term = vim.fn.strcharpart(text, start, cursor - start)
  local key, value = term:match '^(%-?[%w_]+):(.*)$'

  local context, candidates = 'field', {}
  if not key then
    for _, p in ipairs(PREFIXES) do
      if term == '' or p[1]:sub(1, #term):lower() == term:lower() then
        table.insert(candidates, { display = p[1], insert = p[1], cursor_offset = vim.fn.strchars(p[1]), kind = 'field', detail = p[2] })
      end
    end
  else
    context = 'value'
    value = value:gsub('^"', '')
    local project = text:match 'project:(%S+)' or DEFAULT_PROJECT
    for _, v in ipairs(values_for(key:lower(), value, project)) do
      table.insert(candidates, candidate(v[1], key .. ':' .. quote(v[1]) .. ' ', 'value', v[2]))
    end
  end
  out(vim.json.encode { context = context, prefix = term, replace_start = start, replace_end = finish, candidates = candidates })
end

-- -- saved queries ------------------------------------------------------------------------------------------------

local function read_saved()
  local entries = {}
  local file = io.open(SAVED_FILE, 'r')
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

local function saved()
  for _, e in ipairs(read_saved()) do
    out(('%s\t%s\t%s\tsaved'):format(e.label, e.query, e.label))
  end
end

local function save(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  if query == '' then
    fail 'a query is required'
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
    fail 'a label is required'
  end
  local entries = vim.tbl_filter(function(e)
    return e.label ~= label
  end, read_saved())
  table.insert(entries, { label = label, query = query })
  vim.fn.mkdir(vim.fs.dirname(SAVED_FILE), 'p')
  local file = assert(io.open(SAVED_FILE, 'w'))
  for _, e in ipairs(entries) do
    file:write(e.label, '\t', e.query, '\n')
  end
  file:close()
  io.stderr:write('Saved: ' .. label .. '\n')
end

local commands = { search = search, show = show, complete = complete, url = url, saved = saved, save = save }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
