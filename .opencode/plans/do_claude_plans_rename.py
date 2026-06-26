#!/usr/bin/env python3
"""
Rename plan files in this directory so each filename reflects the file's H1 title.
- Uses os.rename (same-filesystem move) to preserve inode and birthtime on macOS HFS+/APFS.
- Preserves any agent-suffix token (e.g. -agent-a8e8b3a) already in the filename.
- Handles collisions by appending -1, -2, etc.
- Skips files that already have the correct name.
- Writes a rename log to rename_log.txt in this directory.
"""

import os
import re
import sys

PLANS_DIR = os.getcwd()
LOG_PATH = os.path.join(PLANS_DIR, "rename_log.txt")

AGENT_SUFFIX_RE = re.compile(r"(-agent-[0-9a-f]+)$", re.IGNORECASE)


def extract_title(filepath):
    """Return the text of the first H1 header found in the file, or None."""
    try:
        with open(filepath, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                m = re.match(r"^#\s+(.+)", line)
                if m:
                    return m.group(1).strip()
    except Exception:
        pass
    return None


def slugify(title):
    """Convert a title string to a lowercase hyphen-separated slug."""
    # Remove common leading prefixes like "Plan:", "Fix:", "Fix Plan:" etc.
    title = re.sub(
        r"^(plan|fix plan|fix|implementation plan|implementation)[:\s]+",
        "",
        title,
        flags=re.IGNORECASE,
    )
    title = title.strip()
    # Lowercase
    title = title.lower()
    # Replace & → and, + → and
    title = title.replace("&", "and").replace("+", "and")
    # Keep only alphanumerics, spaces, hyphens
    title = re.sub(r"[^\w\s-]", "", title)
    # Collapse whitespace/underscores to hyphens
    title = re.sub(r"[\s_]+", "-", title)
    # Collapse multiple hyphens
    title = re.sub(r"-{2,}", "-", title)
    title = title.strip("-")
    return title


def unique_name(directory, slug, agent_suffix, ext, existing_names):
    """Return a filename that doesn't collide with existing_names."""
    base = slug + agent_suffix + ext
    if base not in existing_names:
        return base
    counter = 1
    while True:
        candidate = f"{slug}-{counter}{agent_suffix}{ext}"
        if candidate not in existing_names:
            return candidate
        counter += 1


def main():
    # Accept an optional filename argument
    arg_files = sys.argv[1:]
    if arg_files:
        entries = [
            f for f in arg_files
            if f.endswith(".md")
            and os.path.isfile(os.path.join(PLANS_DIR, f))
            and f not in ("rename_log.txt",)
            and not f.startswith("do_rename")
        ]
    else:
        entries = [
            f
            for f in os.listdir(PLANS_DIR)
            if f.endswith(".md")
            and f not in ("rename_log.txt",)
            and not f.startswith("do_rename")
        ]

    # Build current name set (mutable — updated as we rename)
    existing_names = set(entries)

    if arg_files and not entries:
        print(f"Warning: No valid .md files found among arguments: {arg_files}")



    log_lines = []
    skipped = []
    renamed = []
    no_title = []

    for old_name in sorted(entries):
        old_path = os.path.join(PLANS_DIR, old_name)

        # Detect and strip agent suffix from old name
        stem, ext = os.path.splitext(old_name)
        m = AGENT_SUFFIX_RE.search(stem)
        if m:
            agent_suffix = m.group(1)
            stem_no_agent = stem[: m.start()]
        else:
            agent_suffix = ""
            stem_no_agent = stem

        title = extract_title(old_path)
        if not title:
            no_title.append(old_name)
            log_lines.append(f"NO_TITLE  {old_name}")
            continue

        slug = slugify(title)
        if not slug:
            no_title.append(old_name)
            log_lines.append(f"EMPTY_SLUG  {old_name}  (title: {title!r})")
            continue

        new_base = unique_name(
            PLANS_DIR, slug, agent_suffix, ext, existing_names - {old_name}
        )

        if new_base == old_name:
            skipped.append(old_name)
            log_lines.append(f"SKIP      {old_name}  (already correct)")
            continue

        new_path = os.path.join(PLANS_DIR, new_base)
        try:
            os.rename(old_path, new_path)
            # Update our tracking set
            existing_names.discard(old_name)
            existing_names.add(new_base)
            renamed.append((old_name, new_base, title))
            log_lines.append(f"RENAMED   {old_name}  →  {new_base}  (title: {title!r})")
        except Exception as e:
            log_lines.append(f"ERROR     {old_name}  →  {new_base}  ({e})")

    # Write log
    with open(LOG_PATH, "w", encoding="utf-8") as lf:
        lf.write("\n".join(log_lines) + "\n")
        lf.write(f"\n--- Summary ---\n")
        lf.write(f"Renamed : {len(renamed)}\n")
        lf.write(f"Skipped : {len(skipped)}\n")
        lf.write(f"No title: {len(no_title)}\n")

    print(f"Renamed : {len(renamed)}")
    print(f"Skipped : {len(skipped)}")
    print(f"No title: {len(no_title)}")
    print(f"Log     : {LOG_PATH}")


if __name__ == "__main__":
    main()
