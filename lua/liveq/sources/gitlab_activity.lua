-- GitLab activity (the events of the dashboard/activity page) as a liveq source, backed by
-- backends/gitlab_activity.lua (`nvim -l`, through `glab api`). A row is an event; alt-t groups them under their MR
-- (issue, branch), whose preview is the conversation on it, oldest first.
--
--   require('liveq.sources.gitlab_activity') { project = 'sd/security_director', tree = false, commands = {...}, keymaps = {...} }
--
-- Options: `project` (the project whose members `user:` completes), `host` (default: glab's), `tree` (start grouped),
-- `mr_source` (the name of the `mr` source, whose float alt-m opens: 'mr').
--
-- Keys: `enter` the event (or MR) in the browser · `alt-enter` insert its MR (`project!iid`) · `alt-m` the MR's details
-- · `alt-r` all the events on its MR · `alt-u` only this user's events · `alt-h` hide this user.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'gitlab_activity.lua'))

local function syntax()
  vim.cmd [[
    syntax match gitlabActivityPrefix /\(^\|\s\)\zs-\?\(user\|project\|type\|action\|mr\|branch\|since\|before\|on\|sort\):/
    syntax match gitlabActivityUser /@\w\+/
    syntax region gitlabActivityString start=/"/ end=/"/ oneline
    highlight default link gitlabActivityPrefix Identifier
    highlight default link gitlabActivityUser Special
    highlight default link gitlabActivityString String
  ]]
end

--- The MR (or issue) of an item, `project!iid`, from its title (`author action project!iid title`, or `project!iid
--- title` for a group of the tree).
local function ref_of(item)
  return (item.title or ''):match '([%w._/-]+[!#]%d+)'
end

--- The author of an event, the first word of its title; nil for a group of the tree.
local function author_of(item)
  return item.id:match '^%d+$' and (item.title or ''):match '^(%S+)' or nil
end

--- QUERY without the terms of the given prefixes, then EXTRA.
local function narrow(query, prefixes, extra)
  local kept = {}
  for _, t in ipairs(vim.split(query or '', '%s+', { trimempty = true })) do
    local key = t:match '^(%-?%a+):'
    if not (key and prefixes[key]) then
      table.insert(kept, t)
    end
  end
  vim.list_extend(kept, extra)
  return table.concat(kept, ' ')
end

return function(opts)
  opts = opts or {}
  local env = {}
  if opts.project then
    table.insert(env, 'LIVEQ_GITLAB_PROJECT=' .. opts.project)
  end
  if opts.host then
    table.insert(env, 'LIVEQ_GITLAB_HOST=' .. opts.host)
  end
  local mr_source = opts.mr_source or 'mr'

  local spec
  spec = {
    title = opts.title or 'GitLab activity',
    prompt = opts.prompt or 'activity> ',
    item_name = 'event',
    cmd = function()
      local cmd = #env > 0 and vim.list_extend({ 'env' }, env) or {}
      return vim.list_extend(cmd, { vim.v.progpath, '-l', backend })
    end,
    limit = opts.limit or 100,

    saved = true,
    url = true,
    tree = true,

    -- an event, or a group of the tree (its MR, issue or branch)
    id_pattern = { '^%d+$', '^g:%S+$' },

    filetype = 'gitlabactivity',
    extension = 'gla',
    trigger_characters = { ' ', ':' },
    keyword_pattern = [[\%(\k\|[:@./-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['enter'] = {
        desc = 'browser',
        fn = function(items)
          for _, item in ipairs(items) do
            if item.url ~= '' then
              vim.ui.open(item.url)
            end
          end
        end,
      },
      ['alt-enter'] = {
        desc = 'insert MR',
        fn = function(items)
          local refs = {}
          for _, item in ipairs(items) do
            local ref = ref_of(item)
            if ref and not vim.tbl_contains(refs, ref) then
              table.insert(refs, ref)
            end
          end
          if #refs > 0 then
            vim.api.nvim_put({ table.concat(refs, ', ') }, 'c', true, true)
          end
        end,
      },
      ['alt-m'] = {
        desc = 'MR',
        fn = function(items)
          local ref = items[1] and ref_of(items[1])
          if not (ref and ref:find '!') then
            vim.notify('Not an event on a merge request', vim.log.levels.WARN)
          elseif not require('liveq').sources[mr_source] then
            vim.notify('No liveq source ' .. mr_source .. ' for merge requests', vim.log.levels.WARN)
          else
            require('liveq').show(mr_source, ref)
          end
        end,
      },
      ['alt-r'] = {
        desc = 'on this MR',
        fn = function(items, _, q)
          local ref = items[1] and ref_of(items[1])
          local project, iid = (ref or ''):match '^(.-)!(%d+)$'
          if not iid then
            vim.notify('Not an event on a merge request', vim.log.levels.WARN)
            return
          end
          -- every user's events on it: they are read from the project's activity
          local query = narrow(q, { user = true, project = true, mr = true, type = true, action = true }, { 'project:' .. project, 'mr:' .. iid })
          require('liveq').search(spec.name, query)
        end,
      },
      ['alt-u'] = {
        desc = 'only user',
        fn = function(items, _, q)
          local author = items[1] and author_of(items[1])
          if author then
            require('liveq').search(spec.name, narrow(q, { user = true, ['-user'] = true }, { 'user:' .. author }))
          end
        end,
      },
      ['alt-h'] = {
        desc = 'hide user',
        fn = function(items, _, q)
          local author = items[1] and author_of(items[1])
          if author then
            require('liveq').search(spec.name, narrow(q, {}, { '-user:' .. author }))
          end
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  -- grouped from the start: the picker shows the tree while its state file exists (alt-t removes it)
  if opts.tree then
    spec.tree_state = vim.fn.tempname()
    local f = io.open(spec.tree_state, 'w')
    if f then
      f:close()
    end
  end
  return spec
end
