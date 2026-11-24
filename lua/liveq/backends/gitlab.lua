-- The GitLab merge-request backend of liveq, run with `nvim -l`; it talks to GitLab through `glab api`, so it uses
-- glab's login and host.
--
--   nvim -l gitlab.lua search -f fzf -l LIMIT -- QUERY
--   nvim -l gitlab.lua show [--plain] -- PROJECT!IID           (or !IID, in the default project)
--   nvim -l gitlab.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l gitlab.lua url -- PROJECT!IID
--   nvim -l gitlab.lua saved -f tsv / save [--label NAME] -- QUERY
--   nvim -l gitlab.lua sort -f tsv -- QUERY                     the ways to sort (alt-s in liveq)
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
local C = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'gitlab_common.lua'))
local out, fail, host, encode, api, api_async = C.out, C.fail, C.host, C.encode, C.api, C.api_async
local terms_of, since, user, truncate = C.terms_of, C.since, C.user, C.truncate
local cache_get, cache_set, me = C.cache_get, C.cache_set, C.me
local DAY = C.DAY
local MAX_CANDIDATES = 100

local DEFAULT_PROJECT = os.getenv 'LIVEQ_GITLAB_PROJECT' or 'sd/security_director'
local SAVED_FILE = C.CONFIG_DIR .. '/gitlab-saved.tsv'

-- -- query --------------------------------------------------------------------------------------------------------

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

local candidate, quote = C.candidate, C.quote

local function matching(values, typed)
  return C.matching(values, typed, MAX_CANDIDATES)
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
    return C.users(project == 'all' and DEFAULT_PROJECT or project, typed)
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
    return C.projects(typed, { { 'all', 'every project' }, { DEFAULT_PROJECT, 'default' } })
  end
  return {}
end

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
  local start, finish, term = C.term_at(text, cursor)
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

local function saved()
  C.saved(SAVED_FILE)
end

local function save(opts, rest)
  C.save(SAVED_FILE, opts, rest)
end

-- -- sort ---------------------------------------------------------------------------------------------------------

local SORTS = {
  { 'updated', 'updated ↓ newest first' },
  { 'updated_asc', 'updated ↑ oldest first' },
  { 'created', 'created ↓ newest first' },
  { 'created_asc', 'created ↑ oldest first' },
}

--- The ways to sort the results of QUERY (liveq's `sort -f tsv`): a line per choice, its label and QUERY with its
--- `sort:` term replaced; the current one marked with ●, the default (updated) when there is no `sort:` term.
local function sort(_, rest)
  local query = rest[1] or ''
  local current = query:match '%f[%S]sort:(%S+)' or 'updated'
  local without = vim.trim((query:gsub('%f[%S]sort:%S+', ''):gsub('%s+', ' ')))
  for _, s in ipairs(SORTS) do
    local new = s[1] == 'updated' and without or vim.trim(without .. ' sort:' .. s[1])
    out(('%s %s\t%s'):format(s[1] == current and '●' or ' ', s[2], new))
  end
end

local commands = { search = search, show = show, complete = complete, url = url, saved = saved, save = save, sort = sort }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](C.parse(vim.list_slice(_G.arg, 2)))
