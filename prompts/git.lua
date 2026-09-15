-- Placeholder helpers for prompts in this dir, e.g. ${git.diff}
return {
  diff = function()
    return vim.system({ 'git', 'diff', '--no-ext-diff', '--staged' }, { text = true }):wait().stdout
  end,
}
