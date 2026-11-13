-- linkding bookmark source of liveq, backed by backends/linkding.lua (`nvim -l`). It searches the bookmark cache that
-- the shell's `linkding_search` shares, so typing makes no HTTP call; ctrl-r refetches it.
--
--   require('liveq.sources.linkding') { commands = {...}, keymaps = {...} }
--
-- Needs LINKDING_URL and LINKDING_API_TOKEN in the environment only to fetch the cache or change tags.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'linkding.lua'))

local function syntax()
  vim.cmd [[
    syntax match linkdingQueryTag /-\?#[^ \t]\+/
    syntax match linkdingQueryFlag /!\(unread\|untagged\)\>/
    syntax match linkdingQueryPrefix /\(^\|\s\)\zs\(site\|added\|sort\):/
    syntax region linkdingQueryString start=/"/ end=/"/ oneline
    highlight default link linkdingQueryTag Special
    highlight default link linkdingQueryFlag Keyword
    highlight default link linkdingQueryPrefix Identifier
    highlight default link linkdingQueryString String
  ]]
end

local function urls(items)
  return vim.tbl_map(function(i)
    return i.url
  end, items)
end

return function(opts)
  opts = opts or {}
  local spec
  -- after an action that changed the bookmarks, the picker comes back with the same query
  local function reopen()
    local ok, fzf = pcall(require, 'fzf-lua')
    require('liveq').search(spec.name, ok and fzf.get_last_query() or '')
  end

  spec = {
    title = opts.title or 'Bookmarks (linkding)',
    prompt = opts.prompt or 'bm> ',
    item_name = 'bookmark id',
    cmd = function()
      return { vim.v.progpath, '-l', backend }
    end,
    limit = opts.limit or 300,

    url = true,

    id_pattern = '^%d+$',

    filetype = 'linkdingquery',
    extension = 'ldq',
    trigger_characters = { ' ', '#', ':', '!' },
    keyword_pattern = [[\%(\k\|[#:!.-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['enter'] = {
        desc = 'open',
        fn = function(items)
          for _, u in ipairs(urls(items)) do
            vim.ui.open(u)
          end
        end,
      },
      ['alt-enter'] = {
        desc = 'insert link',
        fn = function(items)
          local links = vim.tbl_map(function(i)
            return ('[%s](%s)'):format((i.title:gsub('[%[%]]', '')), i.url)
          end, items)
          vim.api.nvim_put({ table.concat(links, ', ') }, 'c', true, true)
        end,
      },
      ['ctrl-y'] = {
        desc = 'yank url',
        fn = function(items)
          local text = table.concat(urls(items), '\n')
          vim.fn.setreg('+', text)
          vim.notify('Yanked: ' .. text)
        end,
      },
      ['ctrl-r'] = {
        desc = 'refresh',
        fn = function(_, source)
          vim.notify 'Fetching bookmarks from linkding…'
          if require('liveq.util').run(source, { 'refresh' }, { timeout = 60000 }) then
            reopen()
          end
        end,
      },
      ['ctrl-t'] = {
        desc = 'tags',
        fn = function(items, source)
          if #items == 0 then
            return
          end
          vim.ui.input({ prompt = ('Tags of %d bookmark(s) (#add -#remove): '):format(#items) }, function(changes)
            if changes and vim.trim(changes) ~= '' then
              local args = { 'tag', '--', changes }
              vim.list_extend(
                args,
                vim.tbl_map(function(i)
                  return i.id
                end, items)
              )
              if require('liveq.util').run(source, args) then
                vim.notify(('Tagged %d bookmark(s): %s'):format(#items, changes))
              end
            end
            reopen()
          end)
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  return spec
end
