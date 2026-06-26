# Plan: Add Atlassian Jira MCP to opencode

## Goal
Add a Jira MCP server to `~/.config/opencode/opencode.json` so opencode can query Jira tickets at `coretech-jnpr.atlassian.net`.

## File to modify
`~/.config/opencode/opencode.json`

---

## MCP package
**`@rokealvo/jira-mcp`** (via `npx -y`)
- Runs as a local stdio server
- Auth: `JIRA_BASE_URL` + `JIRA_USER_EMAIL` + `JIRA_API_TOKEN` (basic auth)
- Tools exposed: JQL search, get issue, create, update, transition, comment, list projects

---

## Config entry to add

Inside the existing `"mcp"` block in `~/.config/opencode/opencode.json`, add:

```json
"jira": {
  "type": "local",
  "command": ["npx", "-y", "@rokealvo/jira-mcp"],
  "enabled": true,
  "env": {
    "JIRA_BASE_URL": "https://coretech-jnpr.atlassian.net",
    "JIRA_USER_EMAIL": "<your-atlassian-email>",
    "JIRA_API_TOKEN": "<your-api-token>",
    "JIRA_TYPE": "cloud",
    "JIRA_AUTH_TYPE": "basic"
  }
}
```

---

## Prerequisites (user action required before edit)
1. Generate an Atlassian API token at:
   **https://id.atlassian.com/manage-profile/security/api-tokens**
2. Have your Atlassian account email ready (the one used to log in to coretech-jnpr.atlassian.net)

---

## Steps

1. Read current `~/.config/opencode/opencode.json`
2. Add the `"jira"` entry inside the `"mcp"` block with the credentials supplied by the user
3. Run `npx -y @rokealvo/jira-mcp --help` (or a dry-run) to confirm the package resolves cleanly

---

## Verification
After restarting opencode:
- The Jira MCP server should appear in the available tools list
- Test by asking: *"List my open Jira tickets"* or *"Search Jira for issues in project X"*
- If tools don't appear, check the `mcp_timeout` setting (`experimental.mcp_timeout`) — `npx` cold-starts can be slow on first run

---

## Notes
- Credentials are stored in plain text in `opencode.json` — keep the file permissions tight (`chmod 600 ~/.config/opencode/opencode.json`)
- The `openmemory` and `basic-memory` entries already in the file are `enabled: false` — leave them unchanged
- After saving, quit and restart opencode for the change to take effect
