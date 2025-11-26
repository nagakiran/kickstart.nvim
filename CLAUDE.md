# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Neovim configuration based on [Kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) with significant customizations. It uses **lazy.nvim** for plugin management and is modularized with custom plugins stored in `lua/custom/plugins/`.

**Leader key:** `;` (set in `init.lua:93`)

## Common Development Commands

### Plugin Management
- `:Lazy` - View plugin status and manage plugins
- `:Lazy update` - Update all plugins
- `:Lazy sync` - Install missing, update changed, clean extra plugins
- `:Mason` - View and manage LSP servers, linters, formatters

### Configuration
- `:checkhealth` - Diagnose health of plugins and configuration
- `:Telescope help_tags` - Search Neovim help documentation (also `:search sh`)

### Code Quality
- `:ConformInfo` - View formatting configuration (conform.nvim)
- Format current buffer: `<leader>f` (uses LSP or prettier/stylua)
- Stylua is configured in `.stylua.toml` (column_width=160, 2-space indent)

## Architecture

### File Structure

```
init.lua                  # Main configuration entry point (56KB kickstart base + customizations)
lua/
├── custom/plugins/      # Modularized custom plugins (lazy-loaded)
│   ├── init.lua        # Main plugins list (codecompanion, copilot, avante, markdown, etc.)
│   ├── codecompanion.lua # AI chat integration with history and MCP support
│   ├── avante.lua      # AI editing features
│   ├── lualine.lua     # Status line configuration
│   ├── fzf.lua         # FZF integration
│   ├── fugitive.lua    # Git integration
│   ├── mcphub.lua      # MCP hub configuration
│   └── render_markdown.lua # Markdown rendering customization
├── kickstart/plugins/   # Kickstart builtin plugins (gitsigns, debug)
├── vim.lua             # Vim-specific settings
├── globals.lua         # Global variables and utilities
├── autocommands.lua    # Autocommand definitions
└── tabline.lua         # Custom tab line configuration
vim_fns.vim            # Vim script functions
.stylua.toml           # Stylua formatter configuration (160 column width)
.luarc.json            # Lua LSP configuration
lazy-lock.json         # Plugin lock file (tracked in version control)
```

### Key Architecture Decisions

1. **Lazy.nvim Plugin Manager**: Handles lazy-loading, dependencies, and build steps. Uses `lazy-lock.json` for reproducible builds.

2. **Modular Plugin Organization**: Custom plugins are organized in `lua/custom/plugins/` directory. Each plugin has its own configuration file, making it easy to maintain and understand.

3. **Leader Key**: `;` is used instead of space, allowing easier mapping of common commands.

4. **AI Integration Stack**:
   - **CodeCompanion**: Primary AI chat interface with MCP (Model Context Protocol) support via MCPHub
   - **Copilot**: Inline code suggestions with `<M-l>` to accept, `<M-w>` for word, `<M-e>` for line
   - **Avante**: Alternative AI editing capabilities
   - CodeCompanion has a custom system prompt that enables diff formatting in code blocks

5. **Formatting & Linting**:
   - **conform.nvim**: Autoformat on save (LSP fallback)
   - **Stylua**: Lua formatter (2-space indent, 160 column width)
   - **Prettier**: JavaScript/TypeScript/JSON formatter
   - **pylint/pyright**: Python language server

6. **Git & VCS**:
   - **Gitsigns**: Git change indicators in gutter
   - **Fugitive**: Git commands (:Git)
   - **vim-rooter**: Auto-changes working directory to git root

7. **Treesitter Integration**:
   - Syntax highlighting with context awareness
   - treesitter-context shows function/class context at top of window
   - ts-context-commentstring for intelligent comment formatting

8. **Telescope**: Fuzzy finder for files, buffers, grep, LSP symbols, undo history
   - Custom keymaps for git root grep (`<leader>sG`)
   - Media file preview support
   - Undo tree integration

## LSP Configuration

Configured servers in `init.lua:768-814`:
- **lua_ls**: Lua (with snippet support)
- **ts_ls**: TypeScript/JavaScript
- **pyright**: Python
- **gopls**: Go
- **eslint**: ESLint
- **jdtls**: Java (with custom root_dir pattern)

LSP keymaps:
- `gd` - Go to definition
- `gr` - Find references
- `gI` - Go to implementation
- `<leader>D` - Type definition
- `<leader>ds` - Document symbols
- `<leader>ws` - Workspace symbols
- `<leader>rn` - Rename
- `<leader>ca` - Code action
- `<leader>ph` - Hover information

## Custom Configuration Details

### CodeCompanion Setup (`lua/custom/plugins/codecompanion.lua`)
- Uses **MCPHub** for MCP resource integration
- **History extension** enabled with auto-save (30-day cleanup)
- Custom system prompt that encourages diff formatting in code blocks
- Chat window layout: vertical
- File slash command uses Telescope picker

### Copilot Configuration (`lua/custom/plugins/init.lua`)
- Node.js path: `/Users/nagakiran/.nvm/versions/node/v22.21.1/bin/node`
- Auto-trigger suggestions after 75ms of inactivity
- Enabled on codecompanion and ledger filetypes
- Ghost text styling set explicitly (gray, italic)

### Markdown Rendering
- **render-markdown.nvim** for enhanced markdown display
- Enabled on: markdown, Avante, typescriptreact
- HTML rendering disabled
- Custom highlight for inline code: `RenderMarkdownInlineHighlight`

### Development Tools
- **vim-dadbod-ui**: Database client
- **image.nvim**: Image preview (kitty backend)
- **img-clip.nvim**: Paste images from clipboard
- **vimwiki** + **taskwiki**: Note-taking and task management (with multiple task warriors configured)

## Performance Tuning

- **Large file handling**: Treesitter highlight disabled for files marked with `large_buf` buffer variable
- **Update time**: 250ms (`vim.opt.updatetime`)
- **Timeout length**: 300ms (`vim.opt.timeoutlen`)
- **Scroll offset**: 10 lines (`vim.opt.scrolloff`)
- **Format timeout**: 5000ms (increased from default due to occasional timeouts)

## Customization Patterns

### Adding a New Plugin
1. Create a new file in `lua/custom/plugins/` named after the plugin
2. Return a plugin spec table from the module
3. Import it in `lua/custom/plugins/init.lua` via `{ import = 'custom.plugins' }`
4. Lazy.nvim automatically discovers and loads it

### Modifying Keymaps
- Global keymaps: Add to `init.lua` after line 176
- LSP keymaps: Modify the `on_attach` callback in `init.lua:651-740`
- Plugin-specific keymaps: Add to the plugin's config function

### Debugging
- Use `:checkhealth` to diagnose issues
- Enable verbose mode: `:set verbose=1` (or higher)
- Check CodeCompanion logs: Look in `vim.fn.stdpath('log')`
- For plugin issues, use `:Lazy log` to view plugin load errors

## Important Notes

- **Clipboard sync**: Disabled by default (commented out in `init.lua:129`), as copying from Mac and pasting in Vim was causing override issues
- **Split behavior**: Splitright/splitbelow disabled (for specific window layout needs)
- **Cursorline**: Disabled by default (can enable if needed)
- **Auto-read**: Enabled to reload files changed externally, with checktime on cursor idle
- **Git workdir handling**: Disabled LSP cleanup on buffer delete to avoid stopping global Copilot client across buffers
- **Monorepo support**: `vim-rooter` uses `.vim_rooter` marker or `.git` to find project root, can override with `setup.py` if needed

## Testing & Validation

- Format code: `<leader>f` (uses conform with format_on_save)
- Run diagnostics: `<leader>q` to open quickfix, `<leader>df` to float
- Search help: `<leader>sh` then type query
- Jump to definition: `gd` (with Telescope preview)

## Dependencies

External tools required (installed via Mason):
- `stylua` - Lua code formatter
- `prettier` / `prettierd` - JS/TS/JSON formatter
- Language servers: lua_ls, ts_ls, pyright, gopls, eslint, jdtls
- `ripgrep` - Fast grep search (required by Telescope)
- `make` and C compiler (for telescope-fzf-native)

## References

- [Kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim)
- [Lazy.nvim Documentation](https://lazy.folke.io/)
- [Neovim LSP Guide](https://neovim.io/doc/user/lsp.html)
- [Telescope Documentation](https://github.com/nvim-telescope/telescope.nvim)
- [CodeCompanion Documentation](https://github.com/olimorris/codecompanion.nvim)
