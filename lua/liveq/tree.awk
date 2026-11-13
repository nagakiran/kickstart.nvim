# Draws the branches of a threaded search, like mutt's thread view. Used by liveq's picker as a filter of
# `<backend> search -f fzf --tree`, for any backend: each row is `id \t display \t url \t title \t depth`, in tree order
# (a node, then its children), and its display has \037 where the branches go (else they go before it). Rows without
# a depth (hints, errors, a flat search) pass through as they are.
#
#   ├─> a reply with a later sibling   └─> the last reply   │ the line of an ancestor's later sibling
#
# POSIX awk (macOS, mawk, gawk): the rows are read first, then drawn from the last one up, since a row's branches
# depend on the rows below it.

BEGIN { FS = "\t"; OFS = "\t"; US = sprintf("%c", 31) }

{ row[NR] = $0; depth[NR] = ($5 ~ /^[0-9]+$/) ? $5 + 0 : -1 }

END {
  # more[k]: whether a row at depth k comes below, before any row shallower than k (an ancestor's later sibling)
  for (i = NR; i >= 1; i--) {
    d = depth[i]
    if (d < 0) { line[i] = row[i]; continue }
    prefix = ""
    for (k = 1; k < d; k++) prefix = prefix (more[k] ? "│ " : "  ")
    if (d > 0) prefix = prefix (more[d] ? "├─>" : "└─>")
    if (prefix != "") prefix = "\033[33m" prefix "\033[39m"
    n = split(row[i], f, "\t")
    if (index(f[2], US)) sub(US, prefix, f[2]); else f[2] = prefix f[2]
    out = f[1]
    for (j = 2; j <= n; j++) out = out OFS f[j]
    line[i] = out
    more[d] = 1
    for (k in more) if (k + 0 > d) delete more[k]
  }
  for (i = 1; i <= NR; i++) print line[i]
}
