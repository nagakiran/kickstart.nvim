-- GitLab merge-request source of liveq, backed by backends/gitlab.lua (`nvim -l`, through `glab api`).
--
--   require('liveq.sources.gitlab') { project = 'sd/security_director', repo = '~/stormbreaker/security_director' }
--
-- Options: `title`, `prompt`, `project` (the default project of the queries), `repo` (the local clone in which
-- ctrl-g checks out an MR, alt-d diffs its branches and alt-v opens them in Diffview), `diff_context` (alt-d's `git diff -U`, 50), `host` (default:
-- glab's), `commands`, `keymaps`.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'gitlab.lua'))

local function split_id(id)
  return id:match '^(.*)!(%d+)$'
end

--- Runs CMD (a list) asynchronously and calls ON_OK(stdout) in the main loop; an error is notified instead.
local function run_then(cmd, cwd, on_ok)
  vim.system(cmd, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify(table.concat(cmd, ' ') .. ': ' .. vim.trim(result.stderr or ''), vim.log.levels.ERROR)
        return
      end
      on_ok(result.stdout or '')
    end)
  end)
end

--- Looks up the source and target branches of the MR ID and fetches them in REPO, the local clone; then calls
--- ON_READY(base, feat, mr) with `origin/TARGET` and `origin/SOURCE`.
local function fetch_branches(repo, id, on_ready)
  if not repo or not vim.uv.fs_stat(repo) then
    vim.notify('No local clone (`repo` of the gitlab source) for the branch diff', vim.log.levels.WARN)
    return
  end
  local project, iid = split_id(id)
  vim.notify(('Fetching the branches of %s!%s…'):format(project, iid))
  run_then({ 'glab', 'mr', 'view', iid, '-R', project, '-F', 'json' }, repo, function(out)
    local ok, mr = pcall(vim.json.decode, out)
    if not ok or type(mr) ~= 'table' or not mr.source_branch or not mr.target_branch then
      vim.notify('Could not read the branches of ' .. id, vim.log.levels.ERROR)
      return
    end
    run_then({ 'git', 'fetch', 'origin', mr.target_branch, mr.source_branch }, repo, function()
      on_ready('origin/' .. mr.target_branch, 'origin/' .. mr.source_branch, mr)
    end)
  end)
end

--- A new tab whose directory is REPO, with $JUNIPER_BASE_BRANCH and $JUNIPER_FEATURE_BRANCH set to BASE and FEAT, so
--- that diffview.lua's <leader>dF, <leader>dL and <leader>dJ work in it.
local function branch_tab(repo, base, feat)
  vim.env.JUNIPER_BASE_BRANCH, vim.env.JUNIPER_FEATURE_BRANCH = base, feat
  vim.cmd 'tabnew'
  vim.cmd.tcd(vim.fn.fnameescape(repo))
end

--- alt-d: the MR as the shell's juniper_branch_diff shows it. `git diff -U<context> -w origin/TARGET...origin/SOURCE`
--- in a new tab (see branch_tab): <leader>dF opens the file under the cursor in a 2-way vimdiff, <leader>dL the
--- feature branch's file and <leader>dJ Diffview of the two branches.
local function branch_diff(repo, id, context)
  local project, iid = split_id(id)
  fetch_branches(repo, id, function(base, feat, mr)
    run_then({ 'git', 'diff', '-U' .. context, '-w', base .. '...' .. feat }, repo, function(diff)
      branch_tab(repo, base, feat)
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(diff, '\n', { plain = true }))
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].modifiable = false
      vim.bo[buf].filetype = 'diff'
      pcall(vim.api.nvim_buf_set_name, buf, ('mr://%s!%s %s...%s'):format(project, iid, mr.target_branch, mr.source_branch))
      vim.notify(('%s...%s  ·  ;dF vimdiff  ·  ;dL/;dB feature/base file  ·  ;dJ Diffview  ·  ;dw intra-line'):format(base, feat))
    end)
  end)
end

--- alt-v: Diffview of the MR's branches (`:DiffviewOpen origin/TARGET...origin/SOURCE`), a file panel with each file
--- side by side, opened from a tab rooted at the clone so that Diffview finds the repository; <leader>dq closes it.
local function branch_diffview(repo, id)
  fetch_branches(repo, id, function(base, feat)
    branch_tab(repo, base, feat)
    local scratch = vim.api.nvim_get_current_tabpage()
    vim.cmd('DiffviewOpen ' .. base .. '...' .. feat)
    -- Diffview opens a tab of its own; the empty one it was opened from is not needed
    if vim.api.nvim_tabpage_is_valid(scratch) and scratch ~= vim.api.nvim_get_current_tabpage() then
      vim.cmd(vim.api.nvim_tabpage_get_number(scratch) .. 'tabclose')
    end
  end)
end

local function syntax()
  vim.cmd [[
    syntax match gitlabQueryPrefix /\(^\|\s\)\zs-\?\(state\|author\|assignee\|reviewer\|label\|milestone\|project\|branch\|target\|draft\|created\|updated\|sort\):/
    syntax match gitlabQueryUser /@\w\+/
    syntax region gitlabQueryString start=/"/ end=/"/ oneline
    highlight default link gitlabQueryPrefix Identifier
    highlight default link gitlabQueryUser Special
    highlight default link gitlabQueryString String
  ]]
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
  local repo = opts.repo and vim.fs.normalize(opts.repo) or nil

  return {
    title = opts.title or 'GitLab MRs',
    prompt = opts.prompt or 'mr> ',
    item_name = 'merge request (!IID)',
    cmd = function()
      local cmd = #env > 0 and vim.list_extend({ 'env' }, env) or {}
      return vim.list_extend(cmd, { vim.v.progpath, '-l', backend })
    end,
    limit = opts.limit or 100,

    saved = true,
    url = true,
    sort = true, -- `sort -f tsv`: alt-s picks a `sort:` term

    id_pattern = '^[%w._/-]+!%d+$',
    -- `!123` (in the default project) or `group/project!123`
    cursor_id_pattern = '[%w._/-]*!%d+',

    filetype = 'gitlabquery',
    extension = 'glq',
    trigger_characters = { ' ', ':' },
    keyword_pattern = [[\%(\k\|[:@./-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['ctrl-g'] = {
        desc = 'checkout',
        fn = function(items)
          local item = items[1]
          if not item then
            return
          end
          local project, iid = split_id(item.id)
          vim.cmd 'tabnew'
          vim.fn.jobstart({ 'glab', 'mr', 'checkout', iid, '-R', project }, { term = true, cwd = repo })
          vim.cmd 'startinsert'
        end,
      },
      ['ctrl-d'] = {
        desc = 'diff',
        fn = function(items)
          local item = items[1]
          if not item then
            return
          end
          local project, iid = split_id(item.id)
          -- a large MR takes seconds to fetch; the editor stays usable meanwhile
          vim.notify(('Fetching the diff of %s!%s…'):format(project, iid))
          vim.system({ 'glab', 'mr', 'diff', iid, '-R', project, '--color=never' }, { text = true }, function(result)
            vim.schedule(function()
              if result.code ~= 0 then
                vim.notify(vim.trim(result.stderr or ''), vim.log.levels.ERROR)
                return
              end
              vim.cmd 'tabnew'
              local buf = vim.api.nvim_get_current_buf()
              vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.stdout, '\n', { plain = true }))
              vim.bo[buf].buftype = 'nofile'
              vim.bo[buf].bufhidden = 'wipe'
              vim.bo[buf].filetype = 'diff'
              pcall(vim.api.nvim_buf_set_name, buf, ('mr://%s!%s.diff'):format(project, iid))
            end)
          end)
        end,
      },
      ['alt-d'] = {
        desc = 'branch diff',
        fn = function(items)
          if items[1] then
            branch_diff(repo, items[1].id, opts.diff_context or 50)
          end
        end,
      },
      ['alt-v'] = {
        desc = 'diffview',
        fn = function(items)
          if items[1] then
            branch_diffview(repo, items[1].id)
          end
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
end
