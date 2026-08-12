-- Label shown for a tab: the file's basename, plus a marker for fugitive blob buffers
-- (fugitive://<gitdir>//<sha>/<path>) whose basename alone wouldn't say *which* revision
-- you're looking at. Branch files opened by <leader>dF/<leader>dL carry b:juniper_label
-- ('feat'/'base'); blobs opened from the <leader>sb picker fall back to the short sha.
local function tab_label(bufnr)
  local name = vim.fn.bufname(bufnr)
  if name == '' then
    return '[No Name]'
  end
  local base = vim.fn.fnamemodify(name, ':t')
  if not name:match '^fugitive://' then
    return base
  end
  local label = vim.b[bufnr].juniper_label
  if not label then
    -- FugitiveParse() -> { '<sha>:<path>', '<gitdir>' }; it throws on malformed URLs.
    local ok, parsed = pcall(vim.fn.FugitiveParse, name)
    local sha = ok and type(parsed) == 'table' and parsed[1] and parsed[1]:match '^(%x+):'
    label = sha and sha:sub(1, 7) or 'git'
  end
  return base .. '[' .. label .. ']'
end

-- Custom tabline function
function _G.custom_tabline()
  local tabline = ''
  local tabs = vim.fn.tabpagenr '$'
  local current_tab = vim.fn.tabpagenr()

  for i = 1, tabs do
    -- Highlight current tab
    if i == current_tab then
      tabline = tabline .. '%#TabLineSel#'
    else
      tabline = tabline .. '%#TabLine#'
    end

    -- Add tab number
    tabline = tabline .. ' ' .. i .. ':'

    -- Get list of buffers in the tab
    local buflist = vim.fn.tabpagebuflist(i)
    local winnr = vim.fn.tabpagewinnr(i)
    local bufnr = buflist[winnr]

    -- Add filename
    tabline = tabline .. tab_label(bufnr) .. ' '

    -- Add separator
    if i < tabs then
      tabline = tabline .. '|'
    end
  end

  -- Fill remaining space
  tabline = tabline .. '%#TabLineFill#'

  return tabline
end

-- Set the custom tabline
vim.opt.tabline = '%!v:lua.custom_tabline()'
