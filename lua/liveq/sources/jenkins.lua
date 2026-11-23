-- Jenkins builds as a liveq source, backed by backends/jenkins.lua (`nvim -l`, the JSON API through curl, cached).
-- A row is a build; the tree (on by default, alt-t) shows each build of the chain's root job (baas-sb-build) with the
-- builds it started (sb-build, and ems-nightly, fs-build, sb-nightly under it).
--
--   require('liveq.sources.jenkins') { tree = true, commands = {...}, keymaps = {...} }
--
-- Keys: `enter` the build in a buffer (chain, stages, its job's history on the branch, the end of the console) ·
-- `alt-d` the job's builds on that branch · `alt-l` the whole console in a buffer · `ctrl-r` refresh from the server.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'jenkins.lua'))
local util = require 'liveq.util'

local function syntax()
  vim.cmd [[
    syntax match jenkinsQueryPrefix /\(^\|\s\)\zs-\?\(branch\|job\|result\|is\|user\|since\|on\|mode\|version\|per\):/
    syntax region jenkinsQueryString start=/"/ end=/"/ oneline
    highlight default link jenkinsQueryPrefix Identifier
    highlight default link jenkinsQueryString String
  ]]
end

--- The query without its terms of the given prefixes.
local function without(query, prefixes)
  local kept = {}
  for _, t in ipairs(vim.split(query or '', '%s+', { trimempty = true })) do
    local key = t:match '^%-?(%a+):'
    if not (key and prefixes[key]) then
      table.insert(kept, t)
    end
  end
  return table.concat(kept, ' ')
end

return function(opts)
  opts = opts or {}
  local spec
  spec = {
    title = opts.title or 'Jenkins builds',
    prompt = opts.prompt or 'builds> ',
    item_name = 'build',
    cmd = function()
      return { vim.v.progpath, '-l', backend }
    end,
    limit = opts.limit or 200,

    url = true,
    tree = true,
    header_row = true,

    id_pattern = '^[%w_.%-]+#%d+$',
    cursor_id_pattern = '[%w_.%-]+#%d+',

    filetype = 'jenkinsq',
    extension = 'jkq',
    trigger_characters = { ' ', ':', ',' },
    keyword_pattern = [[\%(\k\|[:./,-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['enter'] = {
        desc = 'build',
        fn = function(items, _, q)
          for _, item in ipairs(items) do
            require('liveq.show').buffer(spec, item.id, { query = q })
          end
        end,
      },
      ['alt-d'] = {
        desc = 'on branch',
        fn = function(items, _, q)
          local item = items[1]
          if not item then
            return
          end
          local job = item.id:match '^(.+)#%d+$'
          local branch = (item.title or ''):match '^(.-) · '
          local narrowed = { without(q, { job = true, branch = true, per = true }), 'job:' .. job }
          if branch and branch ~= '' then
            table.insert(narrowed, 'branch:' .. (branch:find '%s' and ('"' .. branch .. '"') or branch))
          end
          require('liveq').search(spec.name, vim.trim(table.concat(narrowed, ' ')))
        end,
      },
      ['alt-l'] = {
        desc = 'console',
        fn = function(items)
          for _, item in ipairs(items) do
            local text = util.run(spec, { 'log', '--', item.id }, { timeout = 120000 })
            if text then
              local name = 'jenkins://' .. item.id .. '/console'
              local buf = vim.fn.bufnr(name)
              if buf == -1 then
                buf = vim.api.nvim_create_buf(true, true)
                vim.api.nvim_buf_set_name(buf, name)
              end
              vim.bo[buf].modifiable = true
              vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
              vim.bo[buf].modifiable = false
              vim.bo[buf].bufhidden = 'hide'
              vim.api.nvim_set_current_buf(buf)
              vim.cmd 'normal! G'
            end
          end
        end,
      },
      ['ctrl-r'] = {
        desc = 'refresh',
        fn = function(_, _, q)
          vim.notify('Refreshing Jenkins builds…', vim.log.levels.INFO, { title = 'Jenkins' })
          vim.system(vim.list_extend(util.cmd(spec), { 'refresh' }), { text = true }, function(result)
            vim.schedule(function()
              if result.code ~= 0 then
                vim.notify(vim.trim(result.stderr or ''), vim.log.levels.WARN, { title = 'Jenkins' })
              end
              require('liveq').search(spec.name, q)
            end)
          end)
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  -- the tree starts on: the picker shows it while its state file exists (alt-t removes it)
  if opts.tree ~= false then
    spec.tree_state = vim.fn.tempname()
    local f = io.open(spec.tree_state, 'w')
    if f then
      f:close()
    end
  end
  return spec
end
