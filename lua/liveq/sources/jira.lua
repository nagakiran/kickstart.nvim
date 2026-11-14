-- The Jira source of liveq: JQL, backed by `jiratui-jql` (from the jiratui repo).
--
-- `jiratui-jql` has a picker of its own (`pick`), which reloads the values of a field from Jira as you type, so the
-- source uses it rather than the generic one of liveq.

local DEV_BIN = '/opt/nagki/apps/git/jiratui/.venv/bin/jiratui-jql'

local function bin()
  if vim.g.jiratui_jql_bin then
    return vim.g.jiratui_jql_bin
  end
  if vim.fn.executable 'jiratui-jql' == 1 then
    return 'jiratui-jql'
  end
  return DEV_BIN
end

return {
  title = 'Jira (JQL)',
  prompt = 'jql> ',
  item_name = 'work item key',
  cmd = function()
    return { bin() }
  end,
  limit = 100,

  -- the contract's optional commands that jiratui-jql implements
  pick = true,
  saved = true,
  validate = true,
  url = true,
  tree = true, -- `search --tree`: alt-t shows the stories of an epic and the subtasks of a story under them
  sort = true, -- `sort -f tsv`: alt-s sorts by a column shown (ORDER BY)
  header_row = true, -- `search --header`: a first line with the headings of the columns
  -- alt-c cycles through these sets of columns, shown between the key and the summary (`search --columns`; any of
  -- type, status, assignee, reporter, priority, updated, created, due, resolved, resolution, labels, components,
  -- parent, project, or the name or id of any Jira field, custom ones included: Fix-ETA, Sprint, "Story Points",
  -- customfield_10109); the first one is the default
  views = {
    { name = 'default', args = { '--columns', 'type,status,assignee,updated' } },
    { name = 'people', args = { '--columns', 'type,status,assignee,reporter,updated' } },
    { name = 'planning', args = { '--columns', 'type,status,assignee,Fix-ETA,Dev Complete Date,Short Status' } },
    { name = 'labels', args = { '--columns', 'type,status,labels,components' } },
  },

  id_pattern = '^%a[%w_]*%-%d+$',
  cursor_id_pattern = '%u[%u%d]+%-%d+',

  filetype = 'jql',
  extension = 'jql',
  trigger_characters = { ' ', '(', ',', '"' },
  keyword_pattern = [[\%(\k\|[.\[\]-]\)\+]],

  --- One clause per line in the query buffer; the same split as `jiratui-jql edit`.
  split_clauses = function(query)
    return (query:gsub('%s+([Aa][Nn][Dd])%s+', '\n%1 '):gsub('%s+([Oo][Rr])%s+', '\n%1 '):gsub('%s+([Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy])%s+', '\n%1 '))
  end,

  syntax = function()
    vim.cmd [[
      syntax case ignore
      syntax keyword jqlKeyword and or not order by asc desc
      syntax keyword jqlOperator in is was changed empty null from to after before on during
      syntax match jqlSymbol /[!=<>~]\+/
      syntax match jqlFunction /\<\w\+\ze(/
      syntax region jqlString start=/"/ skip=/\\"/ end=/"/ oneline
      syntax region jqlString start=/'/ skip=/\\'/ end=/'/ oneline
      syntax match jqlCustomField /cf\[\d\+\]/
      highlight default link jqlKeyword Keyword
      highlight default link jqlOperator Operator
      highlight default link jqlSymbol Operator
      highlight default link jqlFunction Function
      highlight default link jqlString String
      highlight default link jqlCustomField Identifier
    ]]
  end,

  -- in addition to liveq's (enter insert, alt-enter insert with title, ^o browser, ^y yank, ^v show)
  actions = {
    ['ctrl-t'] = {
      desc = 'tui',
      fn = function(items)
        if items[1] then
          vim.cmd('tabnew | terminal ' .. vim.fn.shellescape(vim.g.jiratui_bin or 'jiratui') .. ' ui -w ' .. vim.fn.shellescape(items[1].id))
          vim.cmd 'startinsert'
        end
      end,
    },
  },

  commands = { search = 'JiraSearch', saved = 'JiraSaved', query = 'JiraJql', show = 'JiraShow' },
  keymaps = { search = '<leader>js', saved = '<leader>jr', query = '<leader>jq', show = '<leader>ji', open = '<leader>jo' },
}
