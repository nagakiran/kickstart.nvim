# liveq

Live, query-driven search of anything that has a query language: you type a query, the results reload as you edit it, and completion helps you write it. The frontend is generic; each source is a backend command that implements a small CLI contract.

- **Neovim** (this directory): fzf-lua live picker, nvim-cmp completion in a query buffer, details float.
- **Shell** (`~/rcfiles/.zsh/liveq.zsh`): `lq <source> [query]` with fzf (`jqls` = `lq jira`, `mls` = `lq mail`), and TAB completion of the query on the command line for sources with their own picker.

It lives inside the Neovim config for now; everything it needs is under `lua/liveq/`, so it can move to a plugin repo as-is.

## Setup

```lua
require('liveq').setup { sources = { jira = require 'liveq.sources.jira' } }
-- in the nvim-cmp config
require('liveq').setup_cmp(cmp)
```

Commands: `:Liveq {source} [query]`, `:LiveqResume [source]` (also `<leader>lr`: reopens the last search with its query and results; one hidden with `alt-esc` comes back exactly as it was, cursor included), `:LiveqSaved {source}`, `:LiveqQuery {source} [query]`, `:LiveqShow {source} [id]`; a source may define its own names and keymaps (Jira: `:JiraSearch`, `:JiraSaved`, `:JiraJql`, `:JiraShow`, `<leader>js/jr/jq/ji/jo`).

Keys in the picker: `tab` complete the query · `ctrl-space` select · `enter` insert the id(s) at the cursor · `alt-enter` insert "id - title" · `ctrl-o` browser · `ctrl-y` yank "id - title" · `ctrl-v` details float · `alt-b` open in a buffer (`liveq://SOURCE/ID`, reused when opened again) · `alt-n`/`alt-p` next/previous match of the query in the preview (sources with `match`) · `alt-t` threaded view (sources with `tree`) · `ctrl-e` edit the query in a buffer with completion (`<CR>` in normal mode or `:w` searches with it) · `ctrl-r`/`ctrl-s` saved queries · `ctrl-q` all results into a Markdown buffer; plus the source's own actions.

## Backend contract

A backend is any executable. Required subcommands:

| Subcommand | Output |
|---|---|
| `search -f fzf -l LIMIT -- QUERY` | One line per item: `id \t display \t url \t title`. `display` may use ANSI colours. Hints, notes and errors are lines with an empty `id` (e.g. `\t\x1b[31mInvalid query\x1b[0m\t`). Exit 0 even for an invalid query, so that fzf shows the message. |
| `show [--plain] -- ID` | The item as text for the preview window (ANSI allowed); with `--plain`, Markdown for the float. `$LIVEQ_WIDTH`, when set, is the text width of the buffer or float that shows it (fzf's preview has `$FZF_PREVIEW_COLUMNS`). Prints nothing for an argument that is not an id (fzf may pass a hint line). |
| `complete -f json [-c CURSOR] -- QUERY` | `{"context": "field\|operator\|value\|keyword\|...", "replace_start": N, "replace_end": N, "candidates": [{"display", "insert", "cursor_offset", "kind", "detail"}]}`. Offsets are in characters; `cursor_offset` is where the cursor goes within `insert`. `context = "value"` means the candidates depend on what is typed, so they are asked for again as the user types. |

Optional subcommands (declared by the source, see below):

| Subcommand | Used for |
|---|---|
| `url -- ID` | Opening the item under the cursor in the browser (`gx` in the float, `open` keymap). |
| `saved -f tsv` / `save [--label L] -- QUERY` | Saved queries: `label \t query \t key \t origin` lines; `save` prompts for the label when it is not given. |
| `pick [--shell] [-c CURSOR] -- TEXT` | A picker of the backend's own (e.g. one that reloads values from the server as you type). Without it, liveq's generic picker (`cli.lua`) is used, which only needs `complete`. |
| `edit -- QUERY` | Editing the query in `$EDITOR` from the shell, e.g. one clause per line. Without it, the query is edited as a single line. |
| `validate -- QUERY` | `<localleader>v` in the query buffer. |
| `search -f fzf -l LIMIT --tree -- QUERY` | The threaded view (`tree = true`), toggled with `alt-t`: rows in tree order (a node, then its children), each with its depth as a 5th field (`id \t display \t url \t title \t depth`, roots at 0) and `\037` in `display` where the branches go (else they go before it). liveq's `tree.awk` draws the branches (`├─>`, `└─>`, `│`) from the depths, so a backend only orders its rows: mail threads, Jira subtasks under their parent or stories under their epic, and so on. Rows without a depth (hints, errors) pass through. |
| `show --match QUERY -- ID` / `terms -- QUERY` | Matches of the query (`match = true`). `show --match` highlights the query's words in the preview and writes the line numbers that have them to `$LIVEQ_MATCH_FILE` (`id`, the index of the match to show first, the numbers separated by spaces). The picker then scrolls the preview to that match (sent to fzf through `--listen` with `curl`, by `cli.lua scroll`, since fzf only takes a scroll offset once the preview is complete); `alt-n`/`alt-p` move to the next and previous ones, shown as "match i/n" on the preview's border. `terms` prints the words as JSON (`[["word"], ["a", "phrase"]]`), so that `alt-b` and `ctrl-v` open the item at its first match with the words in the search register (`n`/`N`). |

## Source spec (Lua)

```lua
{
  title = 'Jira (JQL)', prompt = 'jql> ', item_name = 'work item key',
  cmd = function() return { 'jiratui-jql' } end,  -- or a list, or a string
  limit = 100,
  pick = true, saved = true, validate = true, url = true, match = true, tree = true,  -- optional subcommands it implements
  id_pattern = '^%a[%w_]*%-%d+$',          -- what a real id looks like (filters hint/error lines); a list for several kinds
  cursor_id_pattern = '%u[%u%d]+%-%d+',    -- how to find an id under the cursor in any buffer
  filetype = 'jql', extension = 'jql',     -- the query buffer, and the files that get completion
  trigger_characters = { ' ', '(' }, keyword_pattern = [[\k\+]],
  split_clauses = function(query) return query end,  -- how the query buffer lays out a query
  syntax = function() vim.cmd [[ ... ]] end,
  actions = { ['ctrl-t'] = { desc = 'tui', fn = function(items) end } },  -- items: { id, url, title }
  preview_toggles = { ['alt-h'] = { flag = '--fold', desc = 'fold quotes' } },  -- keys toggling a flag of the preview's `show`
  commands = { search = 'JiraSearch', saved = 'JiraSaved', query = 'JiraJql', show = 'JiraShow' },
  keymaps = { search = '<leader>js', saved = '<leader>jr', query = '<leader>jq', show = '<leader>ji', open = '<leader>jo' },
}
```

In the shell, a source is registered in `liveq.zsh` with `lq_register NAME CMD 'pick edit saved url' EXTENSION`.

## Sources

| Source | Backend |
|---|---|
| `jira` | `jiratui-jql` from the jiratui repo (Python; shares the TUI's auth, JQL parser and saved queries). `alt-t` shows the results as a tree (`search --tree`): each work item followed by its children, i.e. the stories of an epic and the subtasks of a story, two levels down (`parent in (...)`, ten parents per query, all at once); a result that is a child of another result goes under it, and the children that the JQL does not find are dimmed. It takes a few seconds for 100 epics. |
| `mail`, `gmail` | `backends/notmuch.lua`, run with `nvim -l` (no Python, ~40ms start). One source per mailbox, picked with `NOTMUCH_CONFIG` (`mail` = HPE, the primary one; `gmail`). Items are threads. Completes query prefixes, tags, senders/recipients (prefix match, recent ones first), folders, dates and saved query names. Saved queries are notmuch's named queries (`query.NAME`, usable as `query:NAME` anywhere). Extra actions: `ctrl-o` renders the thread as a local HTML page (inline images included, like neomutt's F7 / viewhtmlmsg) and opens it in the browser (`html -- thread:ID` writes it under `$TMPDIR/liveq-mail-*` and prints its path); While typing, the last word also matches as a prefix (notmuch otherwise matches whole words only: `device configu` searches `device (configu or configu*)`). Previews show a thread newest message first (as does the `ctrl-o` page), render the HTML alternatives with w3m when it is installed (in parallel; else the plain ones), `alt-h` folds the quoted history of each reply, the words of the query are highlighted and the preview opens at the first line with the word of the query that is the rarest in the thread (the subject's words are in every message), `alt-n`/`alt-p` step through the matches, `alt-b`/`ctrl-v` open the thread at that match with `n`/`N` going through the rest, `alt-t` switches to a threaded view like mutt's (a row per message, `id:MESSAGE-ID`, with its date and sender and the reply tree; a reply's subject only where it changed; the messages that match the query in normal text and the rest of their threads dimmed, unread ones in bold; the preview and `alt-b` open the thread at that message, and `ctrl-x` tags just that message), and they colour quoted reply headers, `>` quotes, inline comment markers like `[Name]`, @mentions and links. `ctrl-x` changes tags; `alt-o` opens the web client where there is one (`gmail` links to Gmail through the message id; `mail` has none). |

| `mr` | `backends/gitlab.lua`, run with `nvim -l`, talking to GitLab through `glab api` (glab's login and host). Items are merge requests, `project!iid`. Default project `sd/security_director`; `project:all` searches every project (the MRs you authored or review unless you filter by people or words). Query terms mirror GitLab's search bar: `state:` `author:@me` `assignee:` `reviewer:` `label:`/`-label:` `milestone:` `project:` `branch:` `target:` `draft:` `created:7d` `updated:2w` `sort:`; other words search titles and descriptions. Completes users (project members), labels, milestones, branches and projects. Saved queries live in `~/.config/liveq/gitlab-saved.tsv`. Extra actions: `ctrl-g` checkout in the local clone, `ctrl-d` diff. |
| `bm` | `backends/linkding.lua`, run with `nvim -l`. Searches the linkding bookmark cache shared with the shell's `linkding_search` (`~/.cache/linkding/bookmarks.json`), so typing makes no HTTP call; the cache is fetched when missing (needs `LINKDING_URL` / `LINKDING_API_TOKEN`). The query mirrors linkding's search, evaluated locally: words (and `-word`), `#tag` `-#tag` `!unread` `!untagged`, plus `site:HOST` `added:7d` `sort:added\|added_asc\|modified\|title`; the tag being typed also matches as a prefix. Completes tags and sites (most used first). `enter` opens in the browser, `alt-enter` inserts `[title](url)`, `ctrl-y` yanks the URLs, `ctrl-r` refetches the cache, `ctrl-t` changes tags (`#add -#remove`, on all selected), `ctrl-x` deletes the selected bookmarks after a confirmation (on the server and from the cache). `:BookmarkSearch`, `<leader>lk`. |

`sources/notmuch.lua` is a factory: `require('liveq.sources.notmuch') { title, prompt, config, url, primary, commands, keymaps }`. In the shell, `mls` is `lq mail`. `sources/gitlab.lua` is a factory too: `{ project, repo, host, commands, keymaps }`; `mrs` is `lq mr`.
