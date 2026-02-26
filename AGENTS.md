# AGENTS.md

Agent instructions for working in this Neovim configuration repository.

## Repository Overview

This is a personal Neovim configuration based on [Kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim),
using **lazy.nvim** for plugin management. The configuration is written in Lua with some Vimscript.
Leader key is `;` (set in `init.lua:93`).

## Build / Lint / Test Commands

### Formatting (Lua)

The only CI enforced check is Lua formatting via **stylua**:

```sh
# Check formatting (what CI runs)
stylua --check .

# Auto-format all Lua files
stylua .

# Format a single file
stylua lua/custom/plugins/codecompanion.lua
```

Stylua is configured in `.stylua.toml`:
- `column_width = 160`
- `indent_type = "Spaces"`, `indent_width = 2`
- `quote_style = "AutoPreferSingle"`
- `call_parentheses = "None"`
- `line_endings = "Unix"`

### No Test Suite

There are no unit tests in this repository. There is no `Makefile`, `tests/` directory,
or runnable test commands. Validate changes by sourcing the config in Neovim:

```sh
nvim --headless -c 'checkhealth' -c 'qa'
nvim -u init.lua -c ':Lazy check' -c 'qa'
```

### CI

GitHub Actions runs `stylua --check .` on pull requests (`.github/workflows/stylua.yml`).
There are no other CI workflows.

---

## Code Style Guidelines

### Indentation & Formatting

- **2 spaces** for indentation — never tabs.
- Line length target: **160 characters** (enforced by stylua).
- Unix line endings only.
- Trailing whitespace must not be introduced.
- Always run `stylua .` before committing Lua changes.

### Quotes

Prefer **single quotes** for strings. Stylua enforces `AutoPreferSingle` — double quotes
are acceptable only when a string contains a single quote character.

```lua
-- good
local name = 'my_plugin'
vim.cmd 'write'

-- avoid unless necessary
local name = "my_plugin"
```

### Function Call Parentheses

Stylua is configured with `call_parentheses = "None"`. Omit parentheses on single-argument
calls where the argument is a string literal or table constructor:

```lua
-- good
require('telescope').setup { defaults = {} }
vim.cmd 'write'

-- also acceptable (required when chaining or ambiguous)
require('telescope').setup({ defaults = {} })
```

### Imports / `require`

- Use `require` at the top of `config` / `init` functions, not at module top-level,
  to support lazy-loading semantics.
- Assign to a local variable when the module is used more than once:

```lua
config = function()
  local telescope = require('telescope')
  telescope.setup { ... }
  telescope.load_extension('fzf')
end,
```

- Inline single-use requires are common and acceptable:

```lua
config = function()
  require('nvim-surround').setup {}
end,
```

### Naming Conventions

| Context | Convention | Example |
|---|---|---|
| Local variables | `snake_case` | `local my_config = {}` |
| Local functions | `snake_case` | `local function autocmd(event, opts)` |
| Global functions (rare) | `PascalCase` via `_G.*` | `_G.Toggle_venn` |
| `vim.g.*` globals | `snake_case` | `vim.g.taskwiki_sort_orders` |
| `vim.opt.*` options | `snake_case` | `vim.opt.updatetime = 250` |
| Table keys | `snake_case` (unless forced by plugin API) | `data_location`, `taskrc_location` |
| Autocommand groups | `PascalCase` string | `'CustomAutocommands'`, `'CustomLSP'` |

Avoid camelCase in user-authored code. Plugin APIs may use camelCase — match what the
plugin expects.

### Tables & Plugin Specs

Plugin specs are entries in the array returned from `lua/custom/plugins/init.lua`.
Standard shape:

```lua
{
  'author/plugin-name',
  event = 'VeryLazy',           -- or 'VimEnter', 'BufReadPre', ft = {...}, cmd = {...}
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {},                    -- passed directly to plugin's setup(); use instead of config when possible
  config = function()           -- use when setup requires logic beyond a plain opts table
    require('plugin-name').setup {
      key = value,
    }
  end,
  build = function() ... end,   -- post-install build step
  keys = { { '<leader>x', ... } },
}
```

Prefer `opts = { ... }` over `config = function() require(...).setup(opts) end` when no
extra logic is needed — lazy.nvim calls `setup` automatically with `opts`.

### Keymaps

Always provide a `desc` in the options table:

```lua
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
```

For buffer-local LSP keymaps, pass `buffer = event.buf` in opts.

### Autocommands

Group all autocommands via `vim.api.nvim_create_augroup`. Use the helper pattern from
`lua/autocommands.lua`:

```lua
local augroup = vim.api.nvim_create_augroup('CustomAutocommands', { clear = true })
local function autocmd(event, opts)
  opts.group = augroup
  return vim.api.nvim_create_autocmd(event, opts)
end
```

Always pass `{ clear = true }` when creating augroups to prevent duplicate registration
on re-source.

### Error Handling

- Use `pcall` for operations that may fail (filesystem checks, optional requires):

```lua
local ok, stats = pcall(vim.loop.fs_stat, bufname)
if not ok or not stats then return end
```

- Use `vim.notify` to surface messages to the user at appropriate log levels:

```lua
vim.notify('LSP disabled for large buffer: ' .. name, vim.log.levels.INFO)
vim.notify('Something failed: ' .. err, vim.log.levels.ERROR)
```

- Use `error()` only for fatal startup failures (e.g., lazy.nvim bootstrap):

```lua
if vim.v.shell_error ~= 0 then
  error('Error cloning lazy.nvim:\n' .. out)
end
```

- Non-blocking external commands use `vim.system` + `vim.schedule`:

```lua
vim.system({ 'patch', '-d', plugin_path, '-p1', '-i', patch_file }, { text = true }, function(obj)
  vim.schedule(function()
    if obj.code == 0 then
      vim.notify('Patch applied successfully', vim.log.levels.INFO)
    end
  end)
end)
```

### Comments

- Use `--` for single-line comments. No block comments (`--[[ ]]`) unless spanning many lines.
- Commented-out code is acceptable for reference/future use — this is a personal config.
- Add a brief description comment above autocommands, keymaps, and non-obvious logic.

---

## File Structure

```
init.lua                        # Main entry point; options, keymaps, LSP, plugins bootstrap
lua/
  autocommands.lua              # Global autocommands (large buffer LSP disable, etc.)
  globals.lua                   # Global vim options (currently: vim.opt.tabstop = 2)
  vim.lua                       # Vim-specific settings
  tabline.lua                   # Custom tabline
  codecompanion_config.lua      # CodeCompanion config helpers
  avante_config.lua             # Avante config helpers
  custom/plugins/               # Custom plugin specs (auto-discovered by lazy.nvim)
    init.lua                    # Primary plugin list
    codecompanion.lua           # AI chat (CodeCompanion + MCPHub + history)
    avante.lua                  # AI editing (Avante)
    lualine.lua                 # Status line
    fzf.lua                     # FZF integration
    fugitive.lua                # Git (vim-fugitive)
    mcphub.lua                  # MCP hub
    render_markdown.lua         # Markdown rendering
  kickstart/plugins/            # Kickstart-provided plugin specs (do not heavily modify)
after/ftplugin/                 # Filetype-specific settings
after/syntax/                   # Syntax overrides
ftdetect/                       # Custom filetype detection
queries/                        # Treesitter injection queries
.stylua.toml                    # Stylua formatter config
.luarc.json                     # Lua LSP config
lazy-lock.json                  # Plugin lockfile (commit changes to this)
```

---

## Adding New Plugins

1. Create `lua/custom/plugins/<plugin-name>.lua` returning a plugin spec table, **or**
   add a new entry directly to `lua/custom/plugins/init.lua`.
2. Lazy.nvim auto-discovers all files under `lua/custom/plugins/` — no registration needed.
3. Prefer `opts = {}` over explicit `config` when plain options suffice.
4. Run `stylua lua/custom/plugins/<plugin-name>.lua` before committing.

## Cursor/Copilot Rules

No `.cursorrules`, `.cursor/rules/`, or `.github/copilot-instructions.md` files exist
in this repository.
