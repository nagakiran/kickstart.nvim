-- Custom tabline function
function _G.custom_tabline()
  local tabline = ''
  local tabs = vim.fn.tabpagenr('$')
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
    
    -- Get filename
    local filename = vim.fn.bufname(bufnr)
    filename = filename ~= '' and vim.fn.fnamemodify(filename, ':t') or '[No Name]'
    
    -- Add filename
    tabline = tabline .. filename .. ' '
    
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
