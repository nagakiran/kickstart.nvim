#!/bin/sh
# Convert a markdown file to rich text and place it on the macOS pasteboard.
#
# Three flavors are set at once because no single one serves every target:
#   RTF   -> Outlook and other native Mac apps
#   HTML  -> Confluence, Teams and anything else web/Electron based (they
#            ignore the RTF flavor entirely)
#   plain -> the original markdown, for plain-text fields
#
# Usage: md-to-rich-clipboard.sh <markdown-file>

set -eu

md=${1:?usage: md-to-rich-clipboard.sh <markdown-file>}

# AppleScript's `POSIX file` needs an absolute path or it warns and misbehaves.
case $md in
  /*) ;;
  *) md=$(pwd)/$md ;;
esac

if ! command -v pandoc >/dev/null 2>&1; then
  echo "pandoc not found in PATH (brew install pandoc)" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Appearance lives here; this is the one place to tune how the paste looks.
# Confluence and Teams strip CSS and restyle the semantic tags themselves, so
# this mainly governs what Outlook gets by way of the RTF conversion.
cat >"$tmp/style.css" <<'CSS'
body { font-family: Calibri, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; }
code { font-family: Menlo, Consolas, monospace; font-size: 10pt; background-color: #f0f0f0; }
pre { font-family: Menlo, Consolas, monospace; font-size: 10pt; background-color: #f6f8fa; border: 1px solid #dddddd; padding: 8px; }
pre code { background-color: transparent; }
table { border-collapse: collapse; }
th, td { border: 1px solid #999999; padding: 4px 8px; text-align: left; }
th { background-color: #eaeaea; }
blockquote { border-left: 3px solid #cccccc; padding-left: 10px; color: #666666; }
CSS

# hard_line_breaks: plain markdown folds a single newline inside a paragraph into a
# space, so two lines paste as one. Email wants what you typed, so every newline
# becomes a real <br>. The cost is that hard-wrapped prose keeps its wrap points;
# drop the extension if you would rather have paragraphs reflow.
# --embed-resources base64-inlines local images so they survive the paste.
pandoc -f markdown+hard_line_breaks -t html -s \
  --embed-resources \
  --css "$tmp/style.css" \
  --syntax-highlighting=tango \
  -o "$tmp/out.html" \
  "$md"

# textutil honors the embedded CSS, so the RTF keeps fonts, code backgrounds
# and table borders.
textutil -stdin -format html -convert rtf -stdout <"$tmp/out.html" >"$tmp/out.rtf"

# Read from files rather than passing data as arguments: an earlier hexdump/xargs
# approach broke on documents larger than ARG_MAX. The trailing space in
# «class RTF » is significant.
osascript \
  -e 'on run argv' \
  -e 'set h to read (POSIX file (item 1 of argv) as alias) as «class HTML»' \
  -e 'set r to read (POSIX file (item 2 of argv) as alias) as «class RTF »' \
  -e 'set t to read (POSIX file (item 3 of argv) as alias) as «class utf8»' \
  -e 'set the clipboard to {«class HTML»:h, «class RTF »:r, string:t}' \
  -e 'end run' \
  "$tmp/out.html" "$tmp/out.rtf" "$md"
