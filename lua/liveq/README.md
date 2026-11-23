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

Commands: `:Liveq {source} [query]`, `:LiveqResume [source]` (also `<leader>lr`: reopens the last search of any source with its query and results; one hidden with `alt-esc` comes back exactly as it was, cursor included; a source's `resume` keymap/command reopens that source's own last search, whatever was searched since), `:LiveqSaved {source}`, `:LiveqQuery {source} [query]`, `:LiveqShow {source} [id]`; a source may define its own names and keymaps (Jira: `:JiraSearch`, `:JiraSaved`, `:JiraResume`, `:JiraJql`, `:JiraShow`, `<leader>js` search, `jr` resume, `jv` saved, `jq` query, `ji` show, `jo` open). The convention for the keys: `<leader>X` + `s` search, `r` resume, `v` saved, `q` query buffer, `i` show, `o` open (mail `m`, MRs `M`, Teams `t`).

Keys in the picker: `tab` complete the query · `ctrl-space` select · `enter` insert the id(s) at the cursor · `alt-enter` insert "id - title" · `ctrl-o` browser · `alt-x` links of the preview (the one of the message at the current match opens at once when it is the only one there; otherwise all of them are listed on the terminal, that message's first) · `ctrl-y` yank "id - title" · `ctrl-v` details float · `alt-b` open in a buffer (`liveq://SOURCE/ID`, reused when opened again) · `alt-n`/`alt-p` next/previous match of the query in the preview (sources with `match`) · `alt-t` threaded view (sources with `tree`) · `alt-s` sort the results (sources with `sort`: a list of the ways to sort, e.g. by a column shown; the choice is written into the query, so the server sorts and saved queries keep it) · `alt-c` next set of columns (sources with `views`; the prompt names it, e.g. `jql [people]> `) · `alt-f` filter the results already listed instead of querying the server (fuzzy over the whole row; the prompt reads `filter> `, nothing reloads; `alt-f` again restores the query and runs it once more) · `alt-e` edit the query in a buffer with completion (`<CR>` in normal mode or `:w` searches with it) · `ctrl-r`/`ctrl-s` saved queries (`esc` in the list of saved ones goes back to the search) · `ctrl-q` all results into a Markdown buffer; plus the source's own actions.

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
| `url -- ID` | Opening the item under the cursor in the browser (`gx` in the float and the buffer when the cursor is not on a link, which `gx` opens instead; `open` keymap). |
| `saved -f tsv` / `save [--label L] -- QUERY` | Saved queries: `label \t query \t key \t origin` lines; `save` prompts for the label when it is not given. |
| `pick [--shell] [-c CURSOR] -- TEXT` | A picker of the backend's own (e.g. one that reloads values from the server as you type). Without it, liveq's generic picker (`cli.lua`) is used, which only needs `complete`; for a `value` context its query is the whole term (e.g. `target:feat`) and each edit runs `complete` again for it, since a backend returns only the first page of what matches. |
| `edit -- QUERY` | Editing the query in `$EDITOR` from the shell, e.g. one clause per line. Without it, the query is edited as a single line. |
| `validate -- QUERY` | `<localleader>v` in the query buffer. |
| `search -f fzf -l LIMIT --tree -- QUERY` | The threaded view (`tree = true`), toggled with `alt-t`: rows in tree order (a node, then its children), each with its depth as a 5th field (`id \t display \t url \t title \t depth`, roots at 0) and `\037` in `display` where the branches go (else they go before it). liveq's `tree.awk` draws the branches (`├─>`, `└─>`, `│`) from the depths, so a backend only orders its rows: mail threads, Jira subtasks under their parent or stories under their epic, and so on. Rows without a depth (hints, errors) pass through. |
| `search -f fzf ... --header [VIEW ARGS] -- QUERY` | With `header_row = true`, the first line is always the headings of the columns, in the shape of a row with empty fields but the display (`\t headings \t\t`; just `\t\t\t` when there are no rows); fzf keeps it on top (`--header-lines=1`), and hints and errors come after it. With `views`, the arguments of the current view are added (e.g. `--columns type,status,labels`), quoted for the shell, so they may have spaces. |
| `sort -f tsv [VIEW ARGS] -- QUERY` | The ways to sort the results of QUERY (`sort = true`): a line per choice, `label \t new query`, the new query being QUERY with its sort replaced (Jira: its `ORDER BY` clause; GitLab: its `sort:` term). The current order has `●` before its label, and the picker of `alt-s` (`cli.lua sort`) starts on it. The arguments of the current view come too, so a backend can offer the columns shown. |
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
  header_row = true,  -- `search --header` prints a line of column headings first
  tmux = true,  -- in tmux, alt-w (and keymaps.tmux) move the search to the shell's `lq` in a tmux window (real images in its preview); `enter` there runs the `enter` action here; 'default': the search keymap/command open it too
  sort = true,  -- `sort -f tsv` lists ways to sort; alt-s picks one
  views = { { name = 'default', args = { '--columns', 'type,status' } }, { name = 'people', args = { ... } } },  -- alt-c cycles them
  commands = { search = 'JiraSearch', saved = 'JiraSaved', resume = 'JiraResume', query = 'JiraJql', show = 'JiraShow' },
  keymaps = { search = '<leader>js', resume = '<leader>jr', saved = '<leader>jv', query = '<leader>jq', show = '<leader>ji', open = '<leader>jo' },
}
```

In the shell, a source is registered in `liveq.zsh` with `lq_register NAME CMD 'pick edit saved url' EXTENSION`.

## Sources

### `jira`

- `jiratui-jql` from the jiratui repo (Python; shares the TUI's auth, JQL parser and saved queries).
- `alt-t` shows the results as a tree (`search --tree`): each work item followed by its children, i.e. the stories of an epic and the subtasks of a story, two levels down (`parent in (...)`, ten parents per query, all at once); a result that is a child of another result goes under it, and the children that the JQL does not find are dimmed. It takes a few seconds for 100 epics.
- A heading row names the columns, and `alt-c` cycles through sets of them (`views` in `sources/jira.lua`): default (type, status, assignee, updated), people (+ reporter), planning (type, status, assignee, Fix-ETA, Dev Complete Date, Short Status) and labels (type, status, labels, components).
- `jiratui-jql search --columns` takes any of type, status, assignee, reporter, priority, updated, created, due, resolved, resolution, labels, components, parent, project, or the name or id of any Jira field, custom ones included (`Fix-ETA`, `Fix-ETA[Date]`, `"Story Points"`, `customfield_10109`, `cf[10109]`; looked up in the JQL field cache, rendered as the TUI renders them); the key is always first and the summary last.
- `alt-s` sorts by any of the columns shown that Jira can order by (custom fields as `cf[N]`), either way, or back to Jira's default; the heading of the sorted column gets ↑, ↓ (or ↕ when the `ORDER BY` leaves the direction to Jira).

### `mail`, `gmail`

- `backends/notmuch.lua`, run with `nvim -l` (no Python, ~40ms start).
- One source per mailbox, picked with `NOTMUCH_CONFIG` (`mail` = HPE, the primary one; `gmail`).
- Items are threads.
- Completes query prefixes, tags, senders/recipients (prefix match, recent ones first), folders, dates and saved query names.
- Saved queries are notmuch's named queries (`query.NAME`, usable as `query:NAME` anywhere).
- Extra actions: `ctrl-o` renders the thread as a local HTML page (inline images included, like neomutt's F7 / viewhtmlmsg) and opens it in the browser (`html -- thread:ID` writes it under `$TMPDIR/liveq-mail-*` and prints its path);
- While typing, the last word also matches as a prefix (notmuch otherwise matches whole words only: `device configu` searches `device (configu or configu*)`).
- Previews:
  - show a thread newest message first (as does the `ctrl-o` page)
  - render the HTML alternatives with w3m when it is installed (in parallel; else the plain ones)
  - `alt-h` folds the quoted history of each reply
  - the words of the query are highlighted and the preview opens at the first line with the word of the query that is the rarest in the thread (the subject's words are in every message)
  - `alt-n`/`alt-p` step through the matches
  - `alt-b`/`ctrl-v` open the thread at that match with `n`/`N` going through the rest
  - `alt-t` switches to a threaded view like mutt's:
    - a row per message, `id:MESSAGE-ID`, with its date and sender and the reply tree
    - a reply's subject only where it changed
    - the messages that match the query in normal text and the rest of their threads dimmed, unread ones in bold
    - the preview and `alt-b` open the thread at that message, and `ctrl-x` tags just that message
  - they colour quoted reply headers, `>` quotes, inline comment markers like `[Name]`, @mentions and links.
- `ctrl-x` changes tags; `alt-o` opens the web client where there is one (`gmail` links to Gmail through the message id; `mail` has none).
- Inline images (`cid:`), which w3m shows as `[cid]`, read `[image]` (or `[image: ALT]`); `alt-g` opens a gallery of the thread's images, inline and attached (`images -f fzf -- thread:ID`, or `id:` for one message; `image -- MSGID#PART` extracts one from the mail into `~/.cache/liveq/mail-images` and draws it as large as the preview, `--copy` puts it on the clipboard, `--open` opens it): `enter` copies, `ctrl-o` opens; the drawing is `backends/images.lua`, shared with Teams.
- neomutt has the same gallery on `gi` (`~/rcfiles/bin/mail/mail-images.sh`) and shows an image picked in its attachment list in kitty (mailcap, `show-image.sh`).
- `alt-r` replies with Claude Code's `mail-reply` skill (`~/rcfiles/.claude/skills/mail-reply`; neomutt: `gc`): it opens `claude` in a tmux window in `~/stormbreaker/security_director` (`$LIVEQ_MAIL_REPLY_DIR`), which reads the thread, sums up what is asked and asks there for the points to make (several lines, or "suggest"), looks up Jira, MRs and the code, drafts in my mail style and, on approval, saves the reply as an Outlook draft (`make_draft.py` into `~/.mail/hpe/Drafts`, uploaded by `hpe-push-drafts.sh`): HPE mail is sent from Outlook.

### `mr`

- `backends/gitlab.lua`, run with `nvim -l`, talking to GitLab through `glab api` (glab's login and host).
- Items are merge requests, `project!iid`.
- Default project `sd/security_director`; `project:all` searches every project (the MRs you authored or review unless you filter by people or words).
- Query terms mirror GitLab's search bar: `state:` `author:@me` `assignee:` `reviewer:` `label:`/`-label:` `milestone:` `project:` `branch:` `target:` `draft:` `created:7d` `updated:2w` `sort:`; other words search titles and descriptions.
- Completes users (project members), labels, milestones, branches and projects.
- Saved queries live in `~/.config/liveq/gitlab-saved.tsv`.
- Extra actions:
  - `ctrl-g` checkout in the local clone
  - `ctrl-d` diff (GitLab's)
  - `alt-d` branch diff (the shell's `juniper_branch_diff`):
    - fetches the MR's source and target branches in the local clone and opens `git diff -U50 -w origin/TARGET...origin/SOURCE` in a tab rooted at the clone, with `$JUNIPER_BASE_BRANCH`/`$JUNIPER_FEATURE_BRANCH` set
    - so `<leader>dF` opens the file under the cursor in a 2-way vimdiff, `<leader>dL` the feature branch's file and `<leader>dJ` Diffview
    - `diff_context` option, default 50
  - `alt-v` Diffview of the same branches (`:DiffviewOpen origin/TARGET...origin/SOURCE` after the same fetch): changed files in a panel, each side by side; `<leader>dq` closes it.
- `:MrSearch`, `:MrResume`, `:MrSaved`, `<leader>Ms` (search), `<leader>Mr` (resume), `<leader>Mv` (saved), `<leader>Mq` (query), `<leader>Mi` (show), `<leader>Mo` (open).

### `bm`

- `backends/linkding.lua`, run with `nvim -l`.
- Searches the linkding bookmark cache shared with the shell's `linkding_search` (`~/.cache/linkding/bookmarks.json`), so typing makes no HTTP call; the cache is fetched when missing (needs `LINKDING_URL` / `LINKDING_API_TOKEN`).
- The query mirrors linkding's search, evaluated locally: words (and `-word`), `#tag` `-#tag` `!unread` `!untagged`, plus `site:HOST` `added:7d` `sort:added|added_asc|modified|title`; the tag being typed also matches as a prefix.
- Completes tags and sites (most used first).
- `enter` opens in the browser, `alt-enter` inserts `[title](url)`, `ctrl-y` yanks the URLs, `ctrl-r` refetches the cache, `ctrl-t` changes tags (`#add -#remove`, on all selected), `ctrl-x` deletes the selected bookmarks after a confirmation (on the server and from the cache).
- `:BookmarkSearch`, `<leader>lk`.

### `teams`

- `backends/teams.lua`, run with `nvim -l`, talking to Microsoft Graph with curl; the token comes from `~/rcfiles/bin/mail/o365_auth.py token-graph` (the HPE account's Keychain refresh token, `$HPE_MAIL_ADDR` or `LIVEQ_TEAMS_ACCOUNT`) and is cached until it nears expiry, reaching curl through a mode-600 header file, never argv.
- Items are chats, newest activity first, `●` unread.
- Searches a cache of the chat list (`~/.cache/liveq/teams/chats.json`), so typing makes no HTTP call; when the cache is older than `LIVEQ_TEAMS_TTL` (120s) a detached refresh starts and the next keystroke sees it.
- Members are fetched in `$batch` requests and kept while a chat is unchanged (the first refresh of 150 chats takes about a minute, later ones seconds; `$expand=members` inline costs seconds per meeting chat).
- Query: words (chat name, members and message text; `-word` excludes on name, members and last message only), `with:NAME`, `from:me|NAME` (a message sent by you or by that person; with `on:`, that day, so `from:me on:2026-11-17` lists the chats you wrote in that day; `-from:me on:today` those active today without a word from you; the preview jumps to those messages), `type:1:1|group|meeting|calls`, `is:unread`, `has:call`, `since:7d`; completes member names, most frequent first.
- Calls: a call started from a chat posts callStarted/callEnded events into it (the end with duration and people), shown in the chat as `— call · 1h 9m —`; `has:call` lists the chats with one, the row showing the newest call's duration and the count and total (`has:call on:today` for today's).
- A call from the Calls app posts nothing to the chat: Teams logs every call in the hidden thread `48:calllogs`, listed as the chat "Calls" (`cal`, `type:calls`), which Graph strips to the call's id and end time; each entry is joined by that id to the chat event with its duration and people when there is one, else shows `?`.
- On macOS the Teams desktop app caches the whole call log in its IndexedDB: `backends/teams_calls.py` (standard-library Python, read-only: LevelDB tables, the write-ahead log and Snappy, then the `call-log` JSON of each log message) reads it into `calls.json` in the cache, merged so calls the app forgets stay.
- With it, "Calls" lists every call (back to March here, 576 calls in about 4s) with start time, `→`/`←`, duration or `missed`, the people and each day's total; a 1:1 or group chat shows its calls inline (by the other person, or the call's thread); and `has:call` counts them.
- A refresh re-reads it only when Graph's log has a call it lacks (at most every 5 minutes); `nvim -l backends/teams.lua calls` re-reads it now.
- `LIVEQ_TEAMS_DESKTOP_DB` overrides the directory, `''` turns it off; without the app or `python3` the Graph-only view stays.
- "Meetings attended" (`att`, `type:attended`) lists the meetings you joined, by start time, with each meeting's length, its title and head count, and per day the meetings, the time they covered (overlaps counted once) and the day's call time.
- A meeting counts when you are among the people of its callEnded event: Graph's (in the index) and, on macOS, the desktop app's (`teams_calls.py` also reads those, back to January here), joined by call id; titles of meeting chats outside the list are fetched once into `titles.json`.
- Teams keeps no join or leave times (each participant's `<duration>` is the call's length), so the time is the meeting's length, an upper bound.
- Message text is searched locally: Graph's own message search needs `ChannelMessage.Read.All`, which only an admin can consent, so each refresh also fetches the latest 50 messages of every chat whose last message changed (`$batch`), merges them into the chat's message cache and indexes their text (`index.json`).
- Nothing is dropped: messages accumulate (`LIVEQ_TEAMS_KEEP` caps them per chat only when set), and chats that fall out of the newest `LIVEQ_TEAMS_MAX` stay in the list, searchable, until they are active again.
- `refresh --deep [N]` backfills every chat's history to N messages (300; about 1.5 minutes the first time, 9,900 messages back to February in a 2.7MB index, a 56ms search); run it again with a larger N to reach further.
- The whole index is read on each search, so past roughly 15MB (50,000 messages) it would want a different store.
- A chat found through a message shows that message in its row (`↳`, words highlighted) and its preview opens at it (`match`: `alt-n`/`alt-p`).
- If the admin consent is ever granted (`o365_auth.py consent --scope https://graph.microsoft.com/ChannelMessage.Read.All` raises the request), the token carries it without any other change and `search` adds Graph's hits, over all history, to the local ones.
- The preview fetches a chat's messages (newest first) and caches them per chat, keyed by its last message.
- Each `[image]` of the preview is a link (OSC 8) to the cached image as a `.png` (the newest 12 a preview shows are downloaded with it; `LIVEQ_TEAMS_IMAGE_LINKS=0` turns this off):
  - ctrl+shift+click in kitty opens it, in Preview.app by default
  - or over the kitty window with an open action, in `~/.config/kitty/open-actions.conf`:
    - `protocol file`
    - `url .*/liveq/teams/images/.*`
    - `action launch --type=overlay --env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin kitten icat --hold --engine=magick -- ${FILE_PATH}`
    - ImageMagick, since kitten's own conversion turns some white areas black, and Homebrew's PATH, which kitty started from the Dock lacks
  - through tmux it needs `set -as terminal-features ",*:hyperlinks"` (then a reattach).
- In liveq's picker in Neovim the click does nothing: Neovim's terminal (0.12) drops a link that a colour reset follows, and fzf always writes one there; `alt-x` opens the image of the message at the match instead (all of the preview's links in a list when it is not clear which), in tmux in a tmux window of its own (`kitten icat`; any key closes it and tmux goes back to the picker's window; not a popup, since tmux passes no kitty graphics out of one), elsewhere in the image viewer.
- `alt-g` opens a gallery of the chat's images (`images -f fzf -- CHAT_ID` lists them from the message cache, newest first, with date, sender and the start of the message; `image -- URL#WxH` downloads one when it is first shown and draws it as large as the preview; `image --copy` puts it on the clipboard as PNG, `image --open` opens it in the image viewer): `enter` copies, `ctrl-o` opens, `esc` goes back; in Neovim its preview is block art, in the shell's `lq teams` (and its tmux window, `alt-w`) real images.
- `alt-i` draws the images pasted into messages in the preview, in place of `[image]` (fetched from Graph once into `~/.cache/liveq/teams/images`; the newest 12, at most 16 lines tall: `LIVEQ_TEAMS_IMAGE_MAX`, `LIVEQ_TEAMS_IMAGE_ROWS`).
- In Neovim fzf-lua's fzf runs in a `:terminal`, which drops graphics protocols, so the preview draws chafa's block characters, as large as the preview allows, each under a caption `[image K/N]`, and `liveq/images.lua` has image.nvim draw the real image over it (sources with `images = true`: the picker passes `$LIVEQ_IMAGE_FILE`, where `show` lists each image's box and file, and looks for the captions on fzf's screen a few times a second; an image is cropped at the bottom of the window, and one whose caption has scrolled away stays block art).
- Without image.nvim (or a terminal it can draw in) the block art stays; fzf straight in kitty or Ghostty (the shell's `lq teams`, where `alt-i` toggles them too and `LQ_IMAGES=1` starts with them on) gets real pixels through the kitty protocol's unicode placeholders, as large as the preview allows (kitten, converting with ImageMagick when it is installed: kitten's own conversion turns some white areas black): they scroll and crop with the text, go away with it when tmux switches windows, and pass through tmux with `allow-passthrough on`. This is the better way to look at images.
- In tmux, `alt-w` in the Neovim picker moves the search, query and all, to a tmux window of its own with images on, and `<leader>tw` opens one straight away (`tmux = true`, `tmux.lua`, or `tmux = 'default'` for `<leader>ts` too; a window, not a popup, since a popup takes every key and so tmux's prefix): the shell's `lq teams`, with `alt-i` for real images, and `enter` closing it and opening the chat in a Neovim buffer (`enter` prints `id \t title`, `LQ_ACCEPT_NTH=1,4`, to a file Neovim reads once the window's shell signals `tmux wait-for` on exit; Neovim's environment reaches that zsh through a mode-600 file it sources and deletes).
- Outside tmux, or without `~/rcfiles/.zsh/liveq.zsh` (`$LIVEQ_ZSH`), the fzf-lua picker as before.
- `LIVEQ_TEAMS_IMAGE_FORMAT` forces `symbols`, `kitty`, `sixels` or `iterm`; without chafa or kitten the preview stays as it was.
- `enter` opens a chat buffer (`teams://NAME`, oldest at the top, cursor on the newest; opening marks the chat read). Its keys:
  - `r`/`o` reply in a compose split that `:w` sends after a confirmation:
    - `<localleader>id` drafts the reply with Claude: the points typed in the split, the chat's last 20 messages and a guide to my style, `~/rcfiles/.claude/skills/teams-reply/style.md` (`$LIVEQ_TEAMS_STYLE`), go to `claude -p` (Claude Code's CLI and login; `$LIVEQ_TEAMS_DRAFT_MODEL`, default sonnet; no tools, no MCP, no session kept)
      - the split then holds `── draft 1 · short ──`, `── draft 2 · fuller ──`, `── worth adding (not sent) ──` and `── your points (not sent) ──`
      - `:w` sends the draft the cursor is in, `u` brings the points back
      - attached images and files are kept out of the prompt and added to each draft as they were
    - `<localleader>iC` hands the reply to Claude Code's `teams-reply` skill (`~/rcfiles/.claude/skills/teams-reply`, sharing that style guide) for one that needs research: an interactive `claude` in a tmux window of its own, in `~/stormbreaker/security_director` (`$LIVEQ_TEAMS_REPLY_DIR`), given the chat and the split's points; it reads the chat, looks up Jira issues, MRs (`glab`) and the code, shows drafts with their sources and sends only the text approved there
    - images go in as lines `![name](path)` and are sent inline, Graph's hosted contents:
      - `<localleader>ip` pastes the clipboard's image, saved under `~/.cache/nvim/liveq/teams/outgoing` with pngpaste or osascript on macOS, wl-paste or xclip on Linux
      - `<localleader>ia` attaches a file: a PNG, JPEG or GIF inline as `![name](path)`, any other as `[name](path)` (uploaded to `Microsoft Teams Chat Files` in your OneDrive, readable by the chat's members, a card in the message, as Teams does; this needs `Files.ReadWrite`, granted with `o365_auth.py consent --scope https://graph.microsoft.com/Files.ReadWrite ACCOUNT`)
      - the `<localleader>ia` prompt starts with the file on the clipboard (copied in Finder, or a path copied as text; `ctrl-r +` pastes at a prompt, where `ctrl-v` inserts a key literally)
  - `R` reload (always from Graph)
  - `gx` the link under the cursor, else the chat in Teams
  - `ctrl-o` the chat in Teams
  - `q` close
- `alt-r` replies from the picker, `ctrl-r` refreshes.
- `:TeamsChats`, `:TeamsResume`, `<leader>ts`, `<leader>tr`.

### `copilot`

- `backends/copilot.lua`, run with `nvim -l`, reading the request log that copilot-api (the Copilot proxy Claude Code talks to) keeps in SQLite (`~/.local/share/copilot-api/copilot-api.sqlite`, or `$COPILOT_API_SQLITE_DB_PATH`; table `token_usage_events`, one row per request with its time, model, client, session, tokens and cost) with `sqlite3 -readonly`, so the proxy need not be running; its own `/token-usage` API answers only six fixed periods, this any range (~0.1s a query).
- A row is a group of requests: `by:day` (default), `hour`, `week`, `month`, `model`, `session`, `client` (the user agent's first word, e.g. `claude-cli/2.1.328`) or `endpoint`, with requests, input/output/cache tokens, cost and credits (copilot-api's AIU, the unit of the quota's `credits_used`); the first row is the total, and a heading row names the columns.
- Query: `since:7d|2w|1M|12h|DATE|all`, `on:today|yesterday|3d|2026-11-05|11-05|2026-11|A..B` (default: this month), `model:` `client:` `endpoint:` `session:` (a part of it; `-model:` excludes), `sort:time|cost|requests|tokens`, and words (a part of the model, client or session).
- Completes the prefixes, and models, clients and sessions from the log (the most used, or recent, first).
- The preview, `enter` (a buffer) and `ctrl-v` break a row down within the query's filters (they reach `show` through `--match`): by model, then by hour, session and client for a day, by day and session for a model or client, and a session's or an hour's requests one by one.
- `alt-d` drills down: a month or week becomes its days, a day its hours, a model, client or session a filter `by:day` (`by:hour` for a session).
- Registered only where `sqlite3` and the log exist.
- `:CopilotUsage`, `:CopilotUsageResume`, `<leader>Cs`, `<leader>Cr`.

`sources/notmuch.lua` is a factory: `require('liveq.sources.notmuch') { title, prompt, config, url, primary, commands, keymaps }`. In the shell, `mls` is `lq mail`. `sources/gitlab.lua` is a factory too: `{ project, repo, host, commands, keymaps }`; `mrs` is `lq mr`.
