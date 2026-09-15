---
name: Commit message (no wrap)
interaction: chat
description: Generate a commit message without hard-wrapping the body
opts:
  alias: commitmsg
  auto_submit: false
  is_slash_cmd: true
---

## user

You are an expert at following the Conventional Commit specification. Given the git diff listed below, please generate a commit message for me. Do not manually wrap lines in the commit message body - write each bullet point as one continuous line, no matter how long, and let the editor soft-wrap it for display.

`````diff
${git.diff}
`````
