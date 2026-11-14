-- GitLab merge-request source of liveq, backed by backends/gitlab.lua (`nvim -l`, through `glab api`).
--
--   require('liveq.sources.gitlab') { project = 'sd/security_director', repo = '~/stormbreaker/security_director' }
--
-- Options: `title`, `prompt`, `project` (the default project of the queries), `repo` (the local clone in which
-- ctrl-g checks out an MR), `host` (default: glab's), `commands`, `keymaps`.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'gitlab.lua'))

local function split_id(id)
  return id:match '^(.*)!(%d+)$'
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
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
end
