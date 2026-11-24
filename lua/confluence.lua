-- Confluence pages edited as markdown, through scripts/confluence_md.py (which needs pandoc and an Atlassian API token,
-- see its header).
--
--   :ConfluenceOpen URL      pulls the page into a markdown file (its images beside it) and opens it. Saving the file
--                            only saves it: edit, paste screenshots (;p), save as often as you like, then publish.
--   :ConfluenceDiff   (;Cd)  the page as it is on Confluence now, beside the file in diff mode: what a push would
--                            change, others' edits since the pull included.
--   :ConfluencePush[!] (;Cp) saves the file and replaces the page with it. Refuses, with a message, when someone changed
--                            the page since the pull, or when the page has content markdown cannot carry (macros,
--                            mentions...): `!` overrides.
--   :ConfluenceAppend URL    adds the current markdown file (front matter dropped) at the end of the page, leaving the
--                            rest of it alone: the way to add notes and screenshots to a page others edit.
--
-- ;Cd / ;Cp exist in buffers of files with `confluence:` front matter. `vim.g.confluence_autopush = true` makes every
-- save push, as :ConfluencePush.

local M = {}

local script = vim.fn.stdpath 'config' .. '/scripts/confluence_md.py'

local function available()
  if vim.fn.executable 'python3' == 0 or vim.fn.executable 'pandoc' == 0 then
    vim.notify('Confluence: needs python3 and pandoc on PATH', vim.log.levels.WARN)
    return false
  end
  return true
end

--- Runs the script with args; on_done(stdout) when it succeeds, its stderr shown when it fails.
local function run(args, on_done, cwd)
  vim.system({ 'python3', script, unpack(args) }, { text = true, cwd = cwd }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        vim.notify(vim.trim(r.stderr ~= '' and r.stderr or r.stdout), vim.log.levels.ERROR, { title = 'Confluence' })
        return
      end
      if r.stderr ~= '' then
        vim.notify(vim.trim(r.stderr), vim.log.levels.WARN, { title = 'Confluence' })
      end
      on_done(vim.trim(r.stdout))
    end)
  end)
end

--- The page URL in the buffer's front matter, if it has one.
local function linked_page(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 20, false)
  if lines[1] ~= '---' then
    return nil
  end
  for i = 2, #lines do
    if lines[i] == '---' then
      return nil
    end
    local url = lines[i]:match '^confluence:%s*(%S+)'
    if url then
      return url
    end
  end
end

function M.push(buf, force)
  local file = vim.api.nvim_buf_get_name(buf)
  local args = { 'push', file }
  if force then
    table.insert(args, '--force')
  end
  vim.notify('Pushing to Confluence…', vim.log.levels.INFO, { title = 'Confluence' })
  run(args, function(out)
    -- The push wrote the new page version into the front matter: reload it quietly.
    if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd 'silent! checktime'
      end)
    end
    vim.notify('Updated ' .. out, vim.log.levels.INFO, { title = 'Confluence' })
  end)
end

--- The live page pulled into a scratch file, shown beside buf in diff mode.
function M.diff(buf)
  local url = linked_page(buf)
  if not url then
    vim.notify('Confluence: this file has no `confluence:` front matter', vim.log.levels.WARN)
    return
  end
  -- Same file name as buf's, in a scratch dir: the pull names the image dir after it (asset_<stem>), so image paths
  -- match and only real changes show.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local tmp = dir .. '/' .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')
  run({ 'pull', url, '-o', tmp }, function(path)
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
    vim.cmd 'diffthis'
    vim.cmd('vertical diffsplit ' .. vim.fn.fnameescape(path))
    vim.bo.readonly = true
    vim.bo.bufhidden = 'wipe'
    vim.b.confluence_live = true
    vim.notify('Left: the page on Confluence now. Close it with :q, then :diffoff', vim.log.levels.INFO, { title = 'Confluence' })
  end)
end

function M.open(url)
  local id = url:match '/pages/(%d+)' or url:match 'pageId=(%d+)'
  if not id then
    vim.notify('Confluence: no page id in ' .. url, vim.log.levels.ERROR)
    return
  end
  local dir = vim.fn.stdpath 'data' .. '/confluence/' .. id
  vim.fn.mkdir(dir, 'p')
  local existing = vim.fn.glob(dir .. '/*.md', false, true)[1]
  if existing then
    local buf = vim.fn.bufnr(existing)
    if buf ~= -1 and vim.bo[buf].modified then
      vim.notify('Confluence: ' .. existing .. ' has unsaved changes; save or discard them first', vim.log.levels.WARN)
      vim.cmd.edit(vim.fn.fnameescape(existing))
      return
    end
  end
  -- Always pull, so the file starts from the page as it is now (and its current version). A first pull names the
  -- file after the page title.
  run(existing and { 'pull', url, '-o', existing } or { 'pull', url }, function(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.cmd 'silent! checktime'
  end, dir)
end

function M.append(buf, url)
  if vim.bo[buf].modified then
    vim.cmd.write()
  end
  run({ 'append', vim.api.nvim_buf_get_name(buf), '--to', url }, function(out)
    vim.notify('Appended: ' .. out, vim.log.levels.INFO, { title = 'Confluence' })
  end)
end

vim.api.nvim_create_user_command('ConfluenceOpen', function(o)
  if available() then
    M.open(o.args)
  end
end, { nargs = 1, desc = 'Open a Confluence page as markdown, to edit and :ConfluencePush' })

local function push_current(force)
  if not available() then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if not linked_page(buf) then
    vim.notify('Confluence: this file has no `confluence:` front matter (use :ConfluenceAppend URL)', vim.log.levels.WARN)
    return
  end
  if vim.bo[buf].modified then
    vim.cmd 'silent write'
  end
  M.push(buf, force)
end

vim.api.nvim_create_user_command('ConfluencePush', function(o)
  push_current(o.bang)
end, { bang = true, desc = 'Save and push this markdown file to its Confluence page (! overrides the safety checks)' })

vim.api.nvim_create_user_command('ConfluenceDiff', function()
  if available() then
    M.diff(vim.api.nvim_get_current_buf())
  end
end, { desc = 'Diff this markdown file against its Confluence page as it is now' })

vim.api.nvim_create_user_command('ConfluenceAppend', function(o)
  if available() then
    M.append(vim.api.nvim_get_current_buf(), o.args)
  end
end, { nargs = 1, desc = 'Append this markdown file to the end of a Confluence page' })

local group = vim.api.nvim_create_augroup('confluence', { clear = true })

-- Keymaps in files tied to a page (not in the live copy :ConfluenceDiff opens).
vim.api.nvim_create_autocmd('BufReadPost', {
  group = group,
  pattern = '*.md',
  callback = function(ev)
    if not linked_page(ev.buf) or vim.b[ev.buf].confluence_live then
      return
    end
    vim.keymap.set('n', '<localleader>Cp', function()
      push_current(false)
    end, { buffer = ev.buf, desc = 'Confluence: save and push to the page' })
    vim.keymap.set('n', '<localleader>Cd', function()
      M.diff(ev.buf)
    end, { buffer = ev.buf, desc = 'Confluence: diff against the page' })
  end,
})

vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  pattern = '*.md',
  callback = function(ev)
    if vim.g.confluence_autopush and linked_page(ev.buf) and available() then
      M.push(ev.buf, false)
    end
  end,
})

return M
