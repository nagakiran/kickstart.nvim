-- hurlc: Postman-style request collections on top of hurl.nvim.
--
-- A collection is a directory under the root (default ~/patches/juniper/curl); a request is a hurl entry headed by
-- `# @name: ...`. Environments are <root>/envs/<env>.env, each with one or more user/org profiles in
-- <root>/envs/iam-credentials.local.json; the active env/profile is <root>/vars.env, written by `refreshHurlToken`
-- (bin/juniper.sh) and found by hurl.nvim from any subdirectory (it walks up to the git root).
--
--   require('hurlc').pick()        fzf-lua picker over every request: run, edit, copy as curl, import, duplicate
--   require('hurlc').run_cursor()  run the request under the cursor (recorded in the history)
--   require('hurlc').switch_env()  pick an env/profile, log in as that user and org, rewrite vars.env
--   require('hurlc').history()     past responses of the request under the cursor
--
-- Each response hurl.nvim shows for a request started here is also saved to
-- stdpath('state')/hurlc/history/<collection file>/<request>/<time>.json (last HISTORY_KEEP per request), by wrapping
-- hurl.nvim's `history.update_history`, the one place every response passes through.
--
-- KINDS is the seam for other request types: a gRPC kind (grpcurl) needs a `parse` returning the same entry shape;
-- indexing, preview, edit, env and history do not care which kind an entry is. `run_here` still calls HurlRunnerAt
-- directly, so it has to dispatch on `e.kind` when a second kind arrives.

local M = {}

local HISTORY_KEEP = 50
local METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }
local JWT_MASK = [[sed -E 's/(eyJ[A-Za-z0-9_-]{6})[A-Za-z0-9._-]+/\1…/g']]

M.root = vim.fn.expand '~/patches/juniper/curl'
M.history_dir = vim.fn.stdpath 'state' .. '/hurlc/history'

local function notify(msg, level)
  vim.notify('hurlc: ' .. msg, level or vim.log.levels.INFO)
end

local function rel(path)
  local root = M.root .. '/'
  return path:sub(1, #root) == root and path:sub(#root + 1) or vim.fn.fnamemodify(path, ':~')
end

local function slug(s)
  return (s:gsub('[^%w%-_.]+', '_'))
end

--- key=value pairs of an env file (comments and blank lines skipped).
local function read_env(path)
  local vars = {}
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      local k, v = line:match '^%s*([%w_%-.]+)=(.*)$'
      if k and not line:match '^%s*#' then
        vars[k] = v
      end
    end
  end
  return vars
end

--- The active environment as `env/profile` (just `env` for a vars.env written before profiles existed).
function M.active_env()
  local vars = read_env(M.root .. '/vars.env')
  if not vars.env then
    return nil
  end
  return vars.iam_profile and (vars.env .. '/' .. vars.iam_profile) or vars.env
end

--- The entries of a hurl file given as LINES: { name, method, target, start, lnum, stop, index }. `start` is the first
--- of the comment lines directly above the method line (where `# @name:` lives), `stop` the last non-blank line before
--- the next entry's `start`, `index` the entry's 1-based position (hurl's --from-entry).
local function parse_hurl(lines)
  local entries = {}
  for i, line in ipairs(lines) do
    local method, target = line:match '^(%u+)%s+(%S+)'
    if method and METHODS[method] then
      local start, name = i, nil
      while start > 1 and lines[start - 1]:match '^%s*#' do
        start = start - 1
        name = name or lines[start]:match '^%s*#%s*@name:%s*(.-)%s*$'
      end
      for j = start, i - 1 do -- the nearest @name wins if there are several
        name = lines[j]:match '^%s*#%s*@name:%s*(.-)%s*$' or name
      end
      table.insert(entries, { name = name, method = method, target = target, start = start, lnum = i, index = #entries + 1 })
    end
  end
  for k, e in ipairs(entries) do
    local stop = k < #entries and entries[k + 1].start - 1 or #lines
    while stop > e.lnum and vim.trim(lines[stop]) == '' do
      stop = stop - 1
    end
    e.stop = stop
    -- unnamed entries fall back to their path, so a file that was never curated still lists usefully
    e.name = e.name or (e.target:gsub('^https?://[^/]+', ''):gsub('%?.*', ''))
  end
  return entries
end

M.KINDS = {
  hurl = { glob = '**/*.hurl', parse = parse_hurl },
}

--- Every request under the root, ordered by file then position.
function M.index()
  local items = {}
  for kind, spec in pairs(M.KINDS) do
    local files = vim.fn.globpath(M.root, spec.glob, false, true)
    table.sort(files)
    for _, file in ipairs(files) do
      if not file:find('/envs/', 1, true) then
        for _, e in ipairs(spec.parse(vim.fn.readfile(file))) do
          e.kind, e.file, e.rel = kind, file, rel(file)
          table.insert(items, e)
        end
      end
    end
  end
  return items
end

--- The entry of the current buffer that contains the cursor (or the first one below it).
local function entry_at_cursor()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entries = parse_hurl(lines)
  for _, e in ipairs(entries) do
    if row <= e.stop then
      e.file = vim.api.nvim_buf_get_name(0)
      e.rel, e.kind = rel(e.file), 'hurl'
      return e
    end
  end
end

local function open(e)
  vim.cmd('drop ' .. vim.fn.fnameescape(e.file))
  vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
  vim.cmd 'normal! zz'
end

local function block(e)
  return vim.list_slice(vim.fn.readfile(e.file), e.start, e.stop)
end

-- ── running and history ────────────────────────────────────────────────────────────────────────────────────────────

-- ── lookups: variables picked from a live response (pickers/pickers.json) ────────────────────────────────────────

--- The lookup definitions, keyed by variable name: { title, request, rows, header }.
function M.lookups()
  local path = M.root .. '/pickers/pickers.json'
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, defs = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not ok then
    notify('invalid ' .. path .. ': ' .. defs, vim.log.levels.ERROR)
    return {}
  end
  local lookups = {}
  for var, def in pairs(defs) do
    if not var:match '^_' then
      lookups[var] = def
    end
  end
  return lookups
end

--- Sets KEY=VALUE in FILE (replacing the line of KEY, else appending), creating the file.
local function set_kv(file, key, value)
  local lines = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}
  local done = false
  for i, l in ipairs(lines) do
    if l:match('^' .. vim.pesc(key) .. '=') then
      lines[i], done = key .. '=' .. value, true
    end
  end
  if not done then
    table.insert(lines, key .. '=' .. value)
  end
  vim.fn.writefile(lines, file)
end

--- Saves a picked value for the active env: envs/<env>.local.env (kept across env/profile switches, merged into
--- vars.env by refreshHurlToken) and vars.env itself (so the next run sees it at once).
local function save_var(env, key, value)
  set_kv(('%s/envs/%s.local.env'):format(M.root, env), key, value)
  set_kv(M.root .. '/vars.env', key, value)
end

--- The response a lookup's request returns, to CALLBACK(body, err), always on the main loop: vim.system's on_exit
--- runs in a fast event context, where the callback's own vim.system():wait() (jq) raises E5560. Replaceable (tests
--- stub it).
function M.fetch(def, callback)
  vim.system({ 'hurl', '--variables-file', M.root .. '/vars.env', M.root .. '/pickers/' .. def.request }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        callback(nil, vim.trim(res.stderr ~= '' and res.stderr or res.stdout or 'hurl failed'))
      else
        callback(res.stdout)
      end
    end)
  end)
end

--- Picks a value for VAR from its lookup (fetched live with the active env), saves it, then calls ON_DONE(value).
function M.lookup(var, on_done)
  local def = M.lookups()[var]
  local vars = read_env(M.root .. '/vars.env')
  if not def then
    return notify('no lookup for ' .. var .. ' in pickers/pickers.json', vim.log.levels.WARN)
  end
  if not vars.env then
    return notify('no active environment: switch to one first (<leader>he)', vim.log.levels.WARN)
  end
  M.ensure_token(function()
    notify(('fetching %s for %s…'):format(def.title or var, M.active_env()))
    M.fetch(def, function(body, err)
      local rows
      if body then
        local res = vim.system({ 'jq', '-r', def.rows }, { stdin = body, text = true }):wait()
        if res.code ~= 0 then
          err = 'jq: ' .. vim.trim(res.stderr or '') .. ' (response starts: ' .. body:sub(1, 120):gsub('%s+', ' ') .. ')'
        else
          rows = vim.split(res.stdout, '\n', { trimempty = true })
        end
      end
      vim.schedule(function()
        if not rows then
          return notify(('could not fetch %s: %s'):format(def.title or var, err), vim.log.levels.ERROR)
        end
        if #rows == 0 then
          return notify('no ' .. (def.title or var) .. ' found in ' .. M.active_env(), vim.log.levels.WARN)
        end
        -- align the label columns (and the header) by padding, so they line up whatever their widths
        local current, cells, widths = vars[var], {}, {}
        local header = def.header and vim.split(def.header, '\t') or nil
        cells[0] = header -- row 0: the column names, which have no value column
        for i, row in ipairs(rows) do
          cells[i] = vim.split(row, '\t')
        end
        for i = header and 0 or 1, #rows do
          local first = i == 0 and 1 or 2
          for c = first, #cells[i] do
            local col = c - first + 1
            widths[col] = math.max(widths[col] or 0, vim.fn.strdisplaywidth(cells[i][c]))
          end
        end
        local function pad(fields, first)
          local out = {}
          for c = first, #fields do
            local w = widths[c - first + 1]
            table.insert(out, fields[c] .. string.rep(' ', w - vim.fn.strdisplaywidth(fields[c])))
          end
          return table.concat(out, '  ')
        end
        local lines, cells_by_value = {}, {}
        for i = 1, #rows do
          cells_by_value[cells[i][1]] = cells[i][2] or cells[i][1] -- the label saved is the first column (e.g. host name)
          local value = cells[i][1]
          table.insert(lines, ('%s\t%s %s'):format(value, value == current and '●' or ' ', pad(cells[i], 2)))
        end
        require('fzf-lua').fzf_exec(lines, {
          prompt = (def.title or var) .. '> ',
          winopts = { title = (' %s · %s '):format(var, M.active_env()), height = 0.5, width = 0.7, preview = { hidden = true } },
          fzf_opts = {
            ['--delimiter'] = '\t',
            ['--with-nth'] = '2..',
            ['--header'] = header and ('  ' .. pad(cells[0], 1)) or nil,
          },
          actions = {
            ['enter'] = function(selected)
              local fields = selected[1] and vim.split(selected[1], '\t')
              if not fields then
                return
              end
              local label = cells_by_value and cells_by_value[fields[1]] or vim.trim(fields[2] or '')
              save_var(vars.env, var, fields[1])
              save_var(vars.env, var .. '_label', label)
              notify(('%s = %s (%s)'):format(var, label, vars.env))
              if on_done then
                on_done(fields[1])
              end
            end,
          },
        })
      end)
    end)
  end)
end

--- The {{variables}} E uses, in order of first use.
local function vars_used(e)
  local used, seen = {}, {}
  for _, l in ipairs(block(e)) do
    for name in l:gmatch '{{%s*([%w_%-.]+)%s*}}' do
      if not seen[name] then
        seen[name] = true
        table.insert(used, name)
      end
    end
  end
  return used
end

--- Calls ON_READY once every variable E uses that has a lookup is set, picking the missing ones first.
local function ensure_vars(e, on_ready)
  local lookups, vars = M.lookups(), read_env(M.root .. '/vars.env')
  for _, name in ipairs(vars_used(e)) do
    if lookups[name] and (vars[name] or '') == '' then
      return M.lookup(name, function()
        ensure_vars(e, on_ready)
      end)
    end
  end
  on_ready()
end

--- Picks a new value for one of the looked-up variables E uses (any lookup when E uses none, or E is nil).
function M.set_variable(e)
  local lookups = M.lookups()
  local names = {}
  for _, name in ipairs(e and vars_used(e) or {}) do
    if lookups[name] then
      table.insert(names, name)
    end
  end
  if #names == 0 then
    names = vim.tbl_keys(lookups)
    table.sort(names)
  end
  if #names == 0 then
    return notify('no lookups defined in pickers/pickers.json', vim.log.levels.WARN)
  end
  if #names == 1 then
    return M.lookup(names[1])
  end
  local vars = read_env(M.root .. '/vars.env')
  vim.ui.select(names, {
    prompt = 'Variable: ',
    format_item = function(n)
      return ('%-16s %s'):format(n, vars[n .. '_label'] or vars[n] or '(unset)')
    end,
  }, function(n)
    if n then
      M.lookup(n)
    end
  end)
end

local function run_here(e)
  if vim.bo.modified then
    vim.cmd 'write' -- hurl reads the file on disk; an unsaved buffer would shift the entry index
  end
  local buf = vim.api.nvim_get_current_buf()
  M.ensure_token(function()
    ensure_vars(e, function()
      if vim.api.nvim_get_current_buf() ~= buf then
        open(e) -- a lookup picker ran in between
      end
      if vim.api.nvim_win_get_cursor(0)[1] < e.lnum then
        vim.api.nvim_win_set_cursor(0, { e.lnum, 0 }) -- HurlRunnerAt wants the cursor inside the request, not its comments
      end
      -- HurlRunnerAt finds the entry with vim.treesitter.get_node(), which only reads the tree already built; a buffer
      -- the picker just opened is still being parsed asynchronously, so it would see no entry and silently do nothing
      local ok, parser = pcall(vim.treesitter.get_parser, 0, 'hurl')
      if ok and parser then
        parser:parse(true)
      end
      M._ctx = { rel = e.rel, name = e.name, env = M.active_env(), time = os.time() }
      vim.cmd 'HurlRunnerAt'
    end)
  end)
end

function M.run(e)
  open(e)
  run_here(e)
end

function M.run_cursor()
  local e = entry_at_cursor()
  if not e then
    return notify('no request under the cursor', vim.log.levels.WARN)
  end
  run_here(e)
end

--- Picks a new value for a looked-up variable of the request under the cursor.
function M.set_variable_cursor()
  M.set_variable(entry_at_cursor())
end

local function record(response, type)
  local ctx = M._ctx
  M._ctx = nil
  if not ctx or os.time() - ctx.time > 600 then
    return -- a run not started here (e.g. HurlRunner over a whole file): nothing to attribute it to
  end
  local dir = ('%s/%s/%s'):format(M.history_dir, slug(ctx.rel), slug(ctx.name))
  vim.fn.mkdir(dir, 'p')
  local doc = {
    time = os.date '%Y-%m-%d %H:%M:%S',
    env = ctx.env,
    request = ctx.name,
    file = ctx.rel,
    method = response.method,
    url = response.url,
    status = type == 'error' and 'error' or response.status,
    response_time = response.response_time,
    headers = response.headers,
    body = response.body,
    captures = response.captures,
  }
  vim.fn.writefile({ vim.json.encode(doc) }, ('%s/%s.json'):format(dir, os.date '%Y%m%d-%H%M%S'))
  local runs = vim.fn.glob(dir .. '/*.json', false, true)
  table.sort(runs)
  for i = 1, #runs - HISTORY_KEEP do
    vim.fn.delete(runs[i])
  end
end

--- Wraps hurl.nvim's history so each response of a request run from here is also saved to disk.
function M.setup(opts)
  opts = opts or {}
  M.root = opts.root and vim.fn.expand(opts.root) or M.root
  local ok, history = pcall(require, 'hurl.history')
  if ok and not history._hurlc_wrapped then
    local update = history.update_history
    history.update_history = function(response, type)
      pcall(record, response, type)
      return update(response, type)
    end
    history._hurlc_wrapped = true
  end
end

local function scratch(lines, ft, name)
  vim.cmd 'vnew'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

local function response_lines(path)
  local doc = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  local body = doc.body or ''
  local pretty = vim.fn.system({ 'jq', '.' }, body)
  if vim.v.shell_error == 0 then
    body = pretty
  end
  return vim.split(body, '\n', { trimempty = true }), doc
end

--- Past responses of E (the request under the cursor when nil): enter opens one, two selected and ctrl-d diffs them.
function M.history(e)
  e = e or entry_at_cursor()
  if not e then
    return notify('no request under the cursor', vim.log.levels.WARN)
  end
  local dir = ('%s/%s/%s'):format(M.history_dir, slug(e.rel), slug(e.name))
  local runs = vim.fn.glob(dir .. '/*.json', false, true)
  if #runs == 0 then
    return notify('no history for ' .. e.name)
  end
  table.sort(runs, function(a, b)
    return a > b
  end)
  local lines = {}
  for _, path in ipairs(runs) do
    local ok, doc = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
    if ok then
      local status = tostring(doc.status or '?')
      local color = status:match '^2' and '32' or (status:match '^3' and '33' or '31')
      table.insert(
        lines,
        ('%s\t%s  \27[%sm%s\27[0m  %6s ms  \27[2m%s\27[0m'):format(
          path,
          doc.time or '?',
          color,
          status,
          tostring(math.floor(tonumber(doc.response_time) or 0)),
          doc.env or '-'
        )
      )
    end
  end
  local preview = [[jq -r '"\(.method) \(.url)\nstatus \(.status) · \(.response_time) ms · env \(.env)\n"' {1}; ]]
    .. [[jq -r '.body // ""' {1} | (jq -C . 2>/dev/null || jq -r '.body // ""' {1}) | ]]
    .. JWT_MASK
  require('fzf-lua').fzf_exec(lines, {
    prompt = 'history> ',
    winopts = { title = ' ' .. e.name .. ' ', preview = { layout = 'vertical', vertical = 'down:60%' } },
    preview = preview,
    fzf_opts = {
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '2',
      ['--multi'] = true,
      ['--header'] = 'enter open · tab select · ^d diff two',
    },
    actions = {
      ['enter'] = function(selected)
        for _, s in ipairs(selected) do
          local path = vim.split(s, '\t')[1]
          local body, doc = response_lines(path)
          scratch(body, 'json', ('hurlc://%s/%s'):format(e.name, doc.time or path))
        end
      end,
      ['ctrl-d'] = function(selected)
        if #selected ~= 2 then
          return notify('select two runs (tab) to diff', vim.log.levels.WARN)
        end
        vim.cmd 'tabnew'
        local first = true
        for _, s in ipairs(selected) do
          local path = vim.split(s, '\t')[1]
          local body, doc = response_lines(path)
          if first then
            vim.api.nvim_buf_set_lines(0, 0, -1, false, body)
            vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = 'nofile', 'wipe', 'json'
            pcall(vim.api.nvim_buf_set_name, 0, ('hurlc://%s/%s'):format(e.name, doc.time))
            first = false
          else
            scratch(body, 'json', ('hurlc://%s/%s'):format(e.name, doc.time))
          end
          vim.cmd 'diffthis'
        end
      end,
    },
  })
end

-- ── environments ───────────────────────────────────────────────────────────────────────────────────────────────────

local JUNIPER_SH = 'source ~/rcfiles/bin/juniper.sh && HURL_COLLECTIONS_ROOT=%s '

--- Every env/profile pair: { env, profile, user, org } from `listHurlProfiles` (envs/*.env x the iam-credentials
--- files, see refreshHurlToken in bin/juniper.sh). org is '-' when the user's first org is taken.
function M.profiles()
  local cmd = (JUNIPER_SH .. 'listHurlProfiles'):format(vim.fn.shellescape(M.root))
  local result = vim.system({ 'bash', '-c', cmd }, { text = true }):wait(15000)
  local profiles = {}
  for _, line in ipairs(vim.split(result.stdout or '', '\n', { trimempty = true })) do
    local env, profile, user, org = unpack(vim.split(line, '\t'))
    if profile then
      table.insert(profiles, { env = env, profile = profile, user = user, org = org })
    end
  end
  return profiles
end

--- Runs `refreshHurlToken SPEC` (env/profile) in the background, then ON_DONE(ok, message) on the main loop.
function M.refresh(spec, on_done)
  local stderr = {}
  vim.fn.jobstart({ 'bash', '-c', (JUNIPER_SH .. 'refreshHurlToken %s'):format(vim.fn.shellescape(M.root), vim.fn.shellescape(spec)) }, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      stderr = data
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        on_done(code == 0, vim.trim(table.concat(stderr, ' ')))
      end)
    end,
  })
end

--- Seconds until TOKEN (a JWT) expires; nil when it cannot be read.
local function token_ttl(token)
  local payload = token and token:match '^[^.]+%.([^.]+)%.'
  if not payload then
    return nil
  end
  payload = payload:gsub('-', '+'):gsub('_', '/')
  payload = payload .. string.rep('=', (4 - #payload % 4) % 4)
  local ok, claims = pcall(function()
    return vim.json.decode(vim.base64.decode(payload))
  end)
  return ok and type(claims) == 'table' and tonumber(claims.exp) and (claims.exp - os.time()) or nil
end

--- Calls ON_READY with a usable token in vars.env. The token is the one the last switch wrote (it persists across nvim
--- sessions), so normally this is a no-op; once it has expired (IAM tokens last ~30 min) or is about to, it logs in
--- again as the same env/profile first -- refreshHurlToken reuses its own cache when that copy is still good.
function M.ensure_token(on_ready)
  local vars = read_env(M.root .. '/vars.env')
  local ttl = token_ttl(vars.x_iam_token)
  if not vars.env or (ttl and ttl > 60) then
    return on_ready() -- no env chosen yet (requests without a token still run), or the token is good
  end
  local spec = vars.iam_profile and (vars.env .. '/' .. vars.iam_profile) or vars.env
  notify(('token for %s %s, logging in again…'):format(spec, ttl and 'expired' or 'unreadable'))
  M.refresh(spec, function(ok, msg)
    if not ok then
      return notify(('could not refresh the token for %s: %s'):format(spec, msg), vim.log.levels.ERROR)
    end
    on_ready()
  end)
end

--- Picks an env/profile (one fuzzy list, the active one marked) and runs `refreshHurlToken` for it, which logs in
--- with that profile's user and org and rewrites vars.env; then calls ON_DONE (with `env/profile`) on success.
function M.switch_env(on_done)
  local profiles = M.profiles()
  if #profiles == 0 then
    return notify('no profiles: add users to ' .. M.root .. '/envs/iam-credentials.local.json', vim.log.levels.WARN)
  end
  local current = M.active_env()
  local w_env, w_profile, w_user = 0, 0, 0
  for _, p in ipairs(profiles) do
    w_env, w_profile = math.max(w_env, #p.env), math.max(w_profile, #p.profile)
    w_user = math.max(w_user, #p.user)
  end
  vim.ui.select(profiles, {
    prompt = 'Environment / profile' .. (current and (' (now ' .. current .. ')') or '') .. ': ',
    format_item = function(p)
      local mark = (p.env .. '/' .. p.profile) == current and '● ' or '  '
      return ('%s%-' .. w_env .. 's  %-' .. w_profile .. 's  %-' .. w_user .. 's  %s'):format(
        mark,
        p.env,
        p.profile,
        p.user,
        p.org == '-' and '(first org)' or p.org
      )
    end,
  }, function(p)
    if not p then
      return
    end
    local spec = p.env .. '/' .. p.profile
    M.refresh(spec, function(ok, msg)
      if not ok then
        return notify(('could not switch to %s: %s'):format(spec, msg), vim.log.levels.ERROR)
      end
      notify(msg:match 'Wrote .- for (.*)$' or spec)
      if on_done then
        on_done(spec)
      end
    end)
  end)
end

-- ── editing the collections ────────────────────────────────────────────────────────────────────────────────────────

--- E as curl on the clipboard, with {{variables}} filled from the active environment (vars.env).
function M.copy_curl(e)
  local vars = read_env(M.root .. '/vars.env')
  local text = table.concat(block(e), '\n'):gsub('{{%s*([%w_%-.]+)%s*}}', function(k)
    return vars[k]
  end)
  local out = vim.fn.system({ 'hurl2curl' }, text)
  if vim.v.shell_error ~= 0 then
    return notify('hurl2curl failed: ' .. out, vim.log.levels.ERROR)
  end
  vim.fn.setreg('+', out)
  notify('copied as curl: ' .. e.name)
end

--- Appends LINES to FILE (creating it and its directory), a blank line apart from what is there; returns the line
--- number of the first appended line.
local function append(file, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ':h'), 'p')
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #existing > 0 and vim.trim(existing[#existing]) == '' do
    table.remove(existing)
  end
  local at = #existing
  if at > 0 then
    table.insert(lines, 1, '')
  end
  vim.api.nvim_buf_set_lines(buf, at, -1, false, lines)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd 'silent write'
  end)
  return at + (at > 0 and 2 or 1)
end

local function choose_file(on_choice)
  local files = vim.tbl_map(rel, vim.fn.globpath(M.root, '**/*.hurl', false, true))
  table.sort(files)
  table.insert(files, '[new file]')
  vim.ui.select(files, { prompt = 'Collection file: ' }, function(choice)
    if choice == '[new file]' then
      vim.ui.input({ prompt = 'New file (collection/name.hurl): ' }, function(path)
        if path and path ~= '' then
          on_choice(M.root .. '/' .. (path:match '%.hurl$' and path or (path .. '.hurl')))
        end
      end)
    elseif choice then
      on_choice(M.root .. '/' .. choice)
    end
  end)
end

--- A new request from the curl command(s) on the clipboard (e.g. a browser's "Copy as cURL").
function M.import_clipboard()
  local clip = vim.fn.getreg '+'
  if not clip:match 'curl' then
    return notify('the clipboard holds no curl command', vim.log.levels.WARN)
  end
  vim.ui.input({ prompt = 'Request name (empty: from the URL): ' }, function(name)
    if name == nil then
      return
    end
    choose_file(function(file)
      local cmd = { 'python3', vim.fn.expand '~/rcfiles/bin/utils/curl_import.py', '--envs', M.root .. '/envs' }
      if name ~= '' then
        vim.list_extend(cmd, { '--name', name })
      end
      local result = vim.system(cmd, { stdin = clip, text = true }):wait()
      if result.code ~= 0 then
        return notify(vim.trim(result.stderr or 'import failed'), vim.log.levels.ERROR)
      end
      local first = append(file, vim.split(vim.trim(result.stdout), '\n'))
      vim.cmd('drop ' .. vim.fn.fnameescape(file))
      vim.api.nvim_win_set_cursor(0, { first, 0 })
      notify('imported into ' .. rel(file))
    end)
  end)
end

--- A copy of E right after it, under a new name.
function M.duplicate(e)
  vim.ui.input({ prompt = 'Name of the copy: ', default = e.name .. ' (copy)' }, function(name)
    if not name or name == '' then
      return
    end
    local lines, named = block(e), false
    for i, l in ipairs(lines) do
      if l:match '^%s*#%s*@name:' then
        lines[i], named = '# @name: ' .. name, true
      end
    end
    if not named then
      table.insert(lines, e.lnum - e.start + 1, '# @name: ' .. name)
    end
    open(e)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, e.stop, e.stop, false, vim.list_extend({ '' }, lines))
    vim.cmd 'silent write'
    vim.api.nvim_win_set_cursor(0, { e.stop + 2, 0 })
  end)
end

-- ── the picker ─────────────────────────────────────────────────────────────────────────────────────────────────────

local METHOD_COLOR = { GET = '32', POST = '33', PUT = '34', PATCH = '35', DELETE = '31' }

--- The requests picker's title: the looked-up values in force (e.g. the device), so a run's target is visible.
function M.title()
  local vars, parts = read_env(M.root .. '/vars.env'), {}
  for name in pairs(M.lookups()) do
    if vars[name] and vars[name] ~= '' then
      table.insert(parts, name:gsub('_uuid$', '') .. ': ' .. (vars[name .. '_label'] or vars[name]))
    end
  end
  table.sort(parts)
  return ' API requests' .. (#parts > 0 and (' · ' .. table.concat(parts, ' · ')) or '') .. ' '
end

function M.pick()
  local items = M.index()
  if #items == 0 then
    return notify('no requests under ' .. M.root, vim.log.levels.WARN)
  end
  local w_rel, w_name = 0, 0
  for _, e in ipairs(items) do
    w_rel = math.min(math.max(w_rel, vim.fn.strchars((e.rel:gsub('%.hurl$', '')))), 32)
    w_name = math.min(math.max(w_name, vim.fn.strchars(e.name)), 48)
  end
  local by_key, lines = {}, {}
  for _, e in ipairs(items) do
    local key = e.file .. ':' .. e.lnum
    by_key[key] = e
    local coll = e.rel:gsub('%.hurl$', '')
    local path = e.target:gsub('^https?://', ''):gsub('^[^/]*', '')
    table.insert(
      lines,
      table.concat({
        e.file,
        e.start,
        e.stop,
        key,
        ('\27[36m%s\27[0m  %s  \27[%sm%-6s\27[0m \27[2m%s\27[0m'):format(
          coll .. string.rep(' ', w_rel - vim.fn.strchars(coll)),
          e.name .. string.rep(' ', w_name - vim.fn.strchars(e.name)),
          METHOD_COLOR[e.method] or '0',
          e.method,
          path
        ),
      }, '\t')
    )
  end
  local function each(fn)
    return function(selected)
      for _, s in ipairs(selected) do
        local e = by_key[vim.split(s, '\t')[4]]
        if e then
          fn(e)
        end
      end
    end
  end
  local function first(fn)
    return function(selected)
      local e = selected[1] and by_key[vim.split(selected[1], '\t')[4]]
      if e then
        fn(e)
      end
    end
  end
  local env = M.active_env()
  require('fzf-lua').fzf_exec(lines, {
    prompt = (env and ('[' .. env .. '] ') or '') .. 'requests> ',
    winopts = { title = M.title(), preview = { layout = 'vertical', vertical = 'down:55%' } },
    preview = 'sed -n {2},{3}p {1} | ' .. JWT_MASK,
    fzf_opts = {
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '5',
      ['--multi'] = true,
      ['--header'] = 'enter run · ^e/alt-e edit · ^y copy curl · alt-n new from clipboard · alt-d duplicate · ^x env · alt-v set variable · alt-h history · ^q quickfix',
    },
    actions = {
      ['enter'] = first(M.run),
      ['ctrl-e'] = first(open),
      ['alt-e'] = first(open),
      ['ctrl-y'] = first(M.copy_curl),
      ['alt-n'] = function()
        M.import_clipboard()
      end,
      ['alt-d'] = first(M.duplicate),
      ['alt-h'] = first(M.history),
      ['alt-v'] = first(M.set_variable),
      ['ctrl-x'] = function()
        M.switch_env(function()
          M.pick()
        end)
      end,
      ['ctrl-q'] = function(selected)
        local qf = {}
        each(function(e)
          table.insert(qf, { filename = e.file, lnum = e.lnum, text = e.rel .. ' › ' .. e.name })
        end)(selected)
        vim.fn.setqflist(qf, 'r')
        vim.cmd 'copen'
      end,
    },
  })
end

return M
