-- Resolve the git context of a buffer: which repo it belongs to, where it lives inside that
-- repo, and which revision its contents represent.
--
-- Two kinds of buffer are understood:
--   * an ordinary file       -> rev = nil, i.e. the working-tree copy
--   * a fugitive blob buffer -> rev = '<sha>', i.e. the file as of that commit
--     (buffer name looks like  fugitive://<gitdir>//<sha>/<path>)
--
-- Fugitive blobs are how branch files are opened without checking the branch out (see
-- lua/custom/plugins/diffview.lua). Anything that shells out to git for the *current buffer*
-- should route through here so it targets the right repo, path and revision — a worktree's
-- cwd, vim-rooter's lcd and the buffer's own revision can all disagree.

local M = {}

-- True when vim-fugitive is loaded; guards the FugitiveXxx() calls below.
local function has_fugitive()
  return vim.fn.exists '*FugitiveFind' == 1
end

-- The git dir for the current working directory. Used by callers that have no fugitive
-- buffer to key off (e.g. the raw `git diff` buffer piped in by juniper_branch_diff).
-- Returns nil (after notifying) when cwd isn't inside a repo.
function M.gitdir_for_cwd()
  if not has_fugitive() then
    vim.notify('vim-fugitive is not loaded', vim.log.levels.WARN)
    return nil
  end
  local gitdir = vim.fn.FugitiveExtractGitDir(vim.fn.getcwd())
  if gitdir == '' then
    vim.notify('Not inside a git repository: ' .. vim.fn.getcwd(), vim.log.levels.WARN)
    return nil
  end
  return gitdir
end

-- Context of a fugitive blob buffer, or nil if `name` isn't one we can parse.
local function fugitive_ctx(name)
  if not has_fugitive() then
    return nil
  end
  -- FugitiveParse() throws on a malformed fugitive:// URL.
  local ok, parsed = pcall(vim.fn.FugitiveParse, name)
  if not ok or type(parsed) ~= 'table' then
    return nil
  end
  local object, gitdir = parsed[1], parsed[2] -- '<sha>:<path>', '<gitdir>'
  if not object or object == '' or not gitdir or gitdir == '' then
    return nil
  end
  local rev, relpath = object:match '^(.-):(.*)$'
  if not relpath or relpath == '' then
    return nil -- a commit/tree object, not a file blob
  end
  local root = vim.fn.FugitiveWorkTree(gitdir)
  if root == '' then
    return nil -- bare repo: no work tree to anchor paths to
  end
  -- Index objects (':0:path', ':path') aren't commits, so there's no revision to scope
  -- history to — treat them like the working-tree file.
  if not rev:match '^%x%x%x%x%x%x%x' then
    rev = nil
  end
  return { root = root, relpath = relpath, abspath = root .. '/' .. relpath, rev = rev, gitdir = gitdir }
end

-- Context of an ordinary file buffer, or nil if it isn't inside a repo.
local function file_ctx(name)
  local abspath = vim.fn.fnamemodify(name, ':p')
  local out = vim.fn.systemlist { 'git', '-C', vim.fn.fnamemodify(abspath, ':h'), 'rev-parse', '--show-toplevel' }
  local root = out[1]
  if vim.v.shell_error ~= 0 or not root or root == '' then
    return nil
  end
  local relpath = abspath:sub(#root + 2) -- strip 'root/'
  local gitdir = has_fugitive() and vim.fn.FugitiveExtractGitDir(root) or ''
  return { root = root, relpath = relpath, abspath = abspath, rev = nil, gitdir = gitdir ~= '' and gitdir or nil }
end

-- Resolve `bufnr` (default: current buffer) to
--   { root, relpath, abspath, rev, gitdir }  or  nil when it can't be placed in a repo.
function M.for_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == '' then
    return nil
  end
  if name:match '^fugitive://' then
    return fugitive_ctx(name)
  end
  return file_ctx(name)
end

-- Repo root for `bufnr`, falling back to cwd for buffers that aren't in a repo (scratch
-- buffers, `nvim -` stdin, ...). Pickers that only need a directory to run git in use this.
function M.root_for_buf(bufnr)
  local ctx = M.for_buf(bufnr)
  return ctx and ctx.root or vim.fn.getcwd()
end

-- Buffer name for `relpath` at `rev`, e.g. 'fugitive://…//<sha>/lua/init.lua'.
-- `gitdir` defaults to the current buffer's. Returns nil if fugitive can't resolve it.
function M.blob_name(rev, relpath, gitdir)
  if not has_fugitive() then
    return nil
  end
  local ok, name = pcall(vim.fn.FugitiveFind, rev .. ':' .. relpath, gitdir or vim.fn.FugitiveGitDir())
  if not ok or name == '' then
    return nil
  end
  return name
end

-- Does `rev:relpath` exist? Guards opening blobs for files added/deleted on one side of a
-- branch diff, and for commits older than a rename that `git log --follow` walked through.
function M.object_exists(root, rev, relpath)
  vim.fn.system { 'git', '-C', root, 'cat-file', '-e', rev .. ':' .. relpath }
  return vim.v.shell_error == 0
end

-- Open `rev:relpath` as a fugitive blob using `open_cmd` ('tabedit', 'edit', ...) and tag the
-- resulting buffer with `label` (shown by the tabline). Returns true on success; notifies and
-- returns false otherwise.
function M.open_blob(gitdir, rev, relpath, open_cmd, label)
  local name = M.blob_name(rev, relpath, gitdir)
  if not name then
    vim.notify('Could not resolve ' .. rev .. ':' .. relpath, vim.log.levels.WARN)
    return false
  end
  local ok, err = pcall(vim.cmd, open_cmd .. ' ' .. vim.fn.fnameescape(name))
  if not ok then
    vim.notify('Failed to open ' .. rev .. ':' .. relpath .. ' — ' .. tostring(err), vim.log.levels.WARN)
    return false
  end
  if label then
    vim.b.juniper_label = label
  end
  return true
end

return M
