-- Delete/change without clobbering what `p` pastes.
--
-- Workflow this exists for: copy text in the browser, delete the old text in nvim, `p` to paste.
-- With 'clipboard' = unnamedplus, a plain `d`/`c`/`s` writes the deleted text to + and the
-- browser text is gone. Here those operators write to the blackhole register instead; `u` is the
-- way back. (A named register like "d won't do: writing any register makes " point at it, so with
-- 'clipboard' empty (ssh) `p` would still paste the deleted text.)
--
-- Why not gbprod/cutlass.nvim: it maps `d` to a fixed `"_d`, so an explicit `"ad` becomes
-- `"a"_d` and the later register wins. The expr maps below only redirect when no register was
-- typed.
--
-- x/X are left alone on purpose: they stay an explicit cut, so `xp` still swaps characters.
-- Which operators get redirected is set in NOCUT_MAPS below.
local DELETE_REG = '_'

-- The register an operator uses when none was typed, given the current 'clipboard'.
local function default_reg()
  local cb = vim.o.clipboard
  if cb:find 'unnamedplus' then
    return '+'
  elseif cb:find 'unnamed' then
    return '*'
  end
  return '"'
end

-- Operators redirected to DELETE_REG, and the modes each applies in. Anything not listed keeps
-- the stock behaviour (writes the default register).
local NOCUT_MAPS = {
  -- d/D stay a real cut for now: `ddp`-style "delete here, paste there" is too ingrained.
  -- { lhs = 'd', modes = { 'n', 'x' } },
  -- { lhs = 'D', modes = { 'n', 'x' } },
  { lhs = 'c', modes = { 'n', 'x' } },
  { lhs = 'C', modes = { 'n', 'x' } },
  { lhs = 's', modes = { 'n', 'x' } },
  { lhs = 'S', modes = { 'n', 'x' } },
}

for _, map in ipairs(NOCUT_MAPS) do
  local lhs = map.lhs
  vim.keymap.set(map.modes, lhs, function()
    if vim.v.register ~= default_reg() then
      return lhs -- explicit register: honour it
    end
    return '"' .. DELETE_REG .. lhs
  end, { expr = true, desc = 'Delete/change without touching registers' })
end

-- Typing over a selection in select mode (e.g. snippet placeholders) deletes it into the unnamed
-- register too. Send it to the blackhole: nobody wants a placeholder back.
for nr = 33, 126 do
  local char = vim.fn.nr2char(nr)
  vim.keymap.set('s', char, '<C-o>"_c' .. (char == '\\' and '\\\\' or char))
end
vim.keymap.set('s', '<BS>', '<C-o>"_c')
vim.keymap.set('s', '<Space>', '<C-o>"_c<Space>')

-- Visual `p` yanks the replaced text into the default register; `P` doesn't.
vim.keymap.set('x', 'p', 'P', { desc = 'Paste over selection without yanking it' })
