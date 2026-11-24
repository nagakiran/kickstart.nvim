#!/usr/bin/env python3
"""Edit a Confluence Cloud page as markdown: pull it to a .md file, push the file back, or append markdown to a page.

  confluence_md.py pull URL [-o FILE]       page -> FILE (default ./<title>.md), its images into asset_<stem>/ beside it
  confluence_md.py push FILE [--dry-run] [--force]
                                            FILE -> the page named in its front matter (replaces the page body)
  confluence_md.py append FILE --to URL [--dry-run]
                                            FILE's markdown added at the end of the page, the rest left as it is

A pulled file starts with front matter that ties it to the page:

  ---
  confluence: https://SITE.atlassian.net/wiki/spaces/KEY/pages/ID/Title
  confluence_version: 7
  ---

push refuses when the page changed on Confluence since that version (someone else edited it), and when the page holds
Confluence-only content markdown cannot carry (macros, mentions, layouts, status lozenges...), which a push would
delete; --force overrides both. append touches neither, so it is the safe way to add to a page others edit.

Images: a local `![alt](path)` (relative to the file) is uploaded as an attachment of the page, re-uploaded only when
its size changed, and shown inline (<ac:image><ri:attachment/>); a remote `![](https://...)` is shown inline from its
URL. Fenced code becomes a code macro.

Auth: the Atlassian account e-mail from CONFLUENCE_USER, else the `login:` of ~/.config/.jira/.config.yml; the API
token from CONFLUENCE_API_TOKEN, else JIRA_API_TOKEN read from the sops vault (~/rcfiles/secrets.enc.env, when sops and
the vault are there), else JIRA_API_TOKEN from the environment. An Atlassian token works on every site of the account.
Needs pandoc on PATH.
"""

import argparse
import base64
import html
import json
import mimetypes
import os
import re
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


def die(msg):
    print(f'confluence_md: {msg}', file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- HTTP


USER = None


def vault_token():
    """JIRA_API_TOKEN from the sops vault (~/rcfiles/secrets.enc.env, or $SOPS_SECRETS_FILE), read fresh each run, so
    a long-running editor whose environment holds an old token still sends the current one. None without sops/vault."""
    vault = Path(os.environ.get('SOPS_SECRETS_FILE') or Path.home() / 'rcfiles/secrets.enc.env')
    if not shutil.which('sops') or not vault.is_file():
        return None
    r = subprocess.run(['sops', '-d', '--output-type', 'dotenv', str(vault)], capture_output=True, text=True)
    m = re.search(r'^JIRA_API_TOKEN=(.+)$', r.stdout, re.M) if r.returncode == 0 else None
    return m and m.group(1).strip().strip('"\'')


def credentials():
    global USER
    user = os.environ.get('CONFLUENCE_USER')
    if not user:
        cfg = Path.home() / '.config/.jira/.config.yml'
        if cfg.exists():
            m = re.search(r'^login:\s*(\S+)', cfg.read_text(), re.M)
            user = m and m.group(1)
    token = os.environ.get('CONFLUENCE_API_TOKEN') or vault_token() or os.environ.get('JIRA_API_TOKEN')
    if not user or not token:
        die('no credentials: set CONFLUENCE_USER and CONFLUENCE_API_TOKEN (or JIRA_API_TOKEN)')
    USER = user
    return 'Basic ' + base64.b64encode(f'{user}:{token}'.encode()).decode()


AUTH = None


def ssl_context():
    # SSL_CERT_FILE / REQUESTS_CA_BUNDLE name a corporate bundle when there is one. Python 3.13+ also checks
    # certificates strictly (VERIFY_X509_STRICT), which a TLS-inspecting proxy's CA can fail ("Basic Constraints of CA
    # cert not marked critical") although curl and browsers accept it: verify the chain, without that extra check.
    ctx = ssl.create_default_context(cafile=os.environ.get('SSL_CERT_FILE') or os.environ.get('REQUESTS_CA_BUNDLE'))
    ctx.verify_flags &= ~getattr(ssl, 'VERIFY_X509_STRICT', 0)
    return ctx


SSL = ssl_context()


def request(method, url, body=None, headers=None, raw=False):
    global AUTH
    AUTH = AUTH or credentials()
    hdrs = {'Authorization': AUTH, 'Accept': 'application/json'}
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
        hdrs['Content-Type'] = 'application/json'
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=60, context=SSL) as resp:
            data = resp.read()
    except urllib.error.HTTPError as e:
        hint = ''
        if e.code in (401, 403, 404):
            # Confluence treats a token it does not accept as anonymous, so a page you can see answers 404.
            hint = f' (as {USER}: a 404 here usually means the token or e-mail is not accepted on this site)'
        die(f'{method} {url}: HTTP {e.code}{hint}: {e.read().decode(errors="replace")[:300]}')
    except urllib.error.URLError as e:
        die(f'{method} {url}: {e.reason}')
    return data if raw else (json.loads(data) if data else None)


def parse_url(url):
    """(site base like https://x.atlassian.net, page id) from a page URL (/pages/ID/..., ?pageId=ID) or SITE/ID."""
    u = urllib.parse.urlparse(url)
    if not u.scheme or not u.netloc:
        die(f'not a Confluence page URL: {url}')
    m = re.search(r'/pages/(\d+)', u.path) or re.search(r'pageId=(\d+)', u.query)
    if not m:
        die(f'no page id in {url}')
    return f'{u.scheme}://{u.netloc}', m.group(1)


def get_page(base, pid):
    return request('GET', f'{base}/wiki/api/v2/pages/{pid}?body-format=storage')


def attachments(base, pid):
    out, url = {}, f'{base}/wiki/api/v2/pages/{pid}/attachments?limit=250'
    while url:
        d = request('GET', url)
        for a in d.get('results', []):
            out[a['title']] = a
        nxt = d.get('_links', {}).get('next')
        url = f'{base}/wiki{nxt}' if nxt and not nxt.startswith('/wiki') else (f'{base}{nxt}' if nxt else None)
    return out


def upload(base, pid, path, existing):
    """Creates or updates the attachment named like path; skipped when one of the same size is there."""
    name = path.name
    have = existing.get(name)
    if have and have.get('fileSize') == path.stat().st_size:
        return False
    boundary = uuid.uuid4().hex
    ctype = mimetypes.guess_type(name)[0] or 'application/octet-stream'
    body = b''.join(
        [
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'.encode(),
            f'Content-Type: {ctype}\r\n\r\n'.encode(),
            path.read_bytes(),
            f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="minorEdit"\r\n\r\ntrue'.encode(),
            f'\r\n--{boundary}--\r\n'.encode(),
        ]
    )
    request(
        'PUT',
        f'{base}/wiki/rest/api/content/{pid}/child/attachment',
        body,
        {'Content-Type': f'multipart/form-data; boundary={boundary}', 'X-Atlassian-Token': 'no-check'},
    )
    return True


# ---------------------------------------------------------------- conversion


def pandoc(text, src, dst):
    if not shutil.which('pandoc'):
        die('pandoc is not on PATH (brew install pandoc / apt install pandoc)')
    # No syntax highlighting: fenced code must come out as plain <pre class="LANG"><code> for the code macro.
    hl = ['--no-highlight'] if dst == 'html' else []
    r = subprocess.run(['pandoc', '-f', src, '-t', dst, '--wrap=none', *hl], input=text, capture_output=True, text=True)
    if r.returncode:
        die(f'pandoc: {r.stderr.strip()}')
    return r.stdout


# Confluence-only elements: anything ac:/ri: other than what to_markdown turns into markdown.
FOREIGN = re.compile(r'<ac:(?!image\b|structured-macro ac:name="code"|parameter\b|plain-text-body\b)([\w-]+)')


def foreign_elements(storage):
    """The kinds of Confluence-only elements in a storage body, which markdown cannot carry."""
    body = re.sub(r'<ac:structured-macro ac:name="code".*?</ac:structured-macro>', '', storage, flags=re.S)
    return sorted({m.group(1) for m in FOREIGN.finditer(body)})


def to_markdown(storage, asset_dir, rel_dir, fetch):
    """Storage XHTML -> markdown. Attached images are downloaded by fetch(filename, dest) into asset_dir."""
    s = re.sub(r'\s(?:ac:)?local-id="[^"]*"', '', storage)

    def image(m):
        block = m.group(0)
        alt = re.search(r'ac:alt="([^"]*)"', block)
        att = re.search(r'<ri:attachment ri:filename="([^"]*)"', block)
        url = re.search(r'<ri:url ri:value="([^"]*)"', block)
        if att:
            name = html.unescape(att.group(1))
            fetch(name, asset_dir / name)
            src = f'{rel_dir}/{name}'
        elif url:
            src = html.unescape(url.group(1))
        else:
            return ''
        a = html.escape(html.unescape(alt.group(1)) if alt else '')
        return f'<p><img src="{html.escape(src)}" alt="{a}" /></p>'

    s = re.sub(r'<ac:image\b.*?</ac:image>', image, s, flags=re.S)

    def code(m):
        block = m.group(0)
        lang = re.search(r'<ac:parameter ac:name="language">([^<]*)</ac:parameter>', block)
        body = re.search(r'<ac:plain-text-body><!\[CDATA\[(.*?)\]\]></ac:plain-text-body>', block, re.S)
        cls = f' class="language-{lang.group(1)}"' if lang else ''
        return f'<pre><code{cls}>{html.escape(body.group(1) if body else "")}</code></pre>'

    s = re.sub(r'<ac:structured-macro ac:name="code".*?</ac:structured-macro>', code, s, flags=re.S)
    return pandoc(s, 'html', 'gfm').strip() + '\n'


# Image attributes Confluence keeps on <ac:image> (size, layout); markdown has no place for them.
IMAGE_ATTRS = re.compile(r'\s(ac:(?:align|layout|width|height|original-width|original-height|custom-width|border))="[^"]*"')
DEFAULT_WIDTH = 760  # what Confluence gives a pasted screenshot in a full-width page column


def image_attrs(storage):
    """{attachment filename: ' ac:width="760" ...'} for the attached images of a storage body."""
    out = {}
    for m in re.finditer(r'<ac:image\b([^>]*)>\s*<ri:attachment ri:filename="([^"]*)"', storage):
        attrs = ''.join(a.group(0) for a in IMAGE_ATTRS.finditer(m.group(1)))
        if attrs:
            out.setdefault(html.unescape(m.group(2)), attrs)
    return out


def known_image_attrs(base, page, names, history=10):
    """Image attributes for the attachments in names: from the page, else from its latest earlier version that has
    them (which repairs a page an older push of this script left without sizes)."""
    attrs = image_attrs(page['body']['storage']['value'])
    missing = set(names) - set(attrs)
    v = page['version']['number'] - 1
    while missing and v > 0 and history > 0:
        old = request('GET', f'{base}/wiki/api/v2/pages/{page["id"]}?body-format=storage&version={v}')
        for name, a in image_attrs(old['body']['storage']['value']).items():
            if name in missing:
                attrs[name] = a
                missing.discard(name)
        v, history = v - 1, history - 1
    return attrs


def png_size(path):
    """(width, height) of a PNG, else None."""
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] == b'\x89PNG\r\n\x1a\n':
        return int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big')
    return None


def default_attrs(path):
    """Centred, at most DEFAULT_WIDTH wide: how Confluence's editor places a pasted screenshot."""
    size = png_size(path)
    if not size:
        return ' ac:align="center" ac:layout="center"'
    w, h = size
    return (
        f' ac:align="center" ac:layout="center" ac:original-width="{w}" ac:original-height="{h}"'
        f' ac:custom-width="true" ac:width="{min(w, DEFAULT_WIDTH)}"'
    )


def image_names(markdown, md_dir):
    """File names of the local images markdown shows (attachment names)."""
    names = []
    for src in re.findall(r'!\[[^\]]*\]\(([^)\s]+)', markdown):
        if not re.match(r'https?://', src):
            names.append(Path(urllib.parse.unquote(src)).name)
    return names


def to_storage(markdown, md_dir, attrs=None):
    """Markdown -> storage XHTML, and the local image files it shows (to upload). attrs: {filename: attributes} to
    keep on images already on the page; others get default_attrs."""
    attrs = attrs or {}
    out = pandoc(markdown, 'gfm', 'html')
    local = []

    def image(m):
        tag = m.group(0)
        src = html.unescape(re.search(r'src="([^"]*)"', tag).group(1))
        alt = re.search(r'alt="([^"]*)"', tag)
        alt_attr = f' ac:alt="{alt.group(1)}"' if alt and alt.group(1) else ''
        if re.match(r'https?://', src):
            return f'<ac:image{alt_attr}><ri:url ri:value="{html.escape(src)}" /></ac:image>'
        path = (md_dir / urllib.parse.unquote(src)).expanduser().resolve()
        if not path.is_file():
            die(f'image not found: {src} (looked for {path})')
        local.append(path)
        alt_attr += attrs.get(path.name) or default_attrs(path)
        return f'<ac:image{alt_attr}><ri:attachment ri:filename="{html.escape(path.name)}" /></ac:image>'

    out = re.sub(r'<img\b[^>]*>', image, out)

    def code(m):
        lang = m.group(1)
        body = html.unescape(m.group(2)).replace(']]>', ']]]]><![CDATA[>')
        param = f'<ac:parameter ac:name="language">{lang}</ac:parameter>' if lang else ''
        return f'<ac:structured-macro ac:name="code">{param}<ac:plain-text-body><![CDATA[{body}]]></ac:plain-text-body></ac:structured-macro>'

    out = re.sub(r'<pre(?: class="(\w[\w+-]*)")?><code>(.*?)</code></pre>', code, out, flags=re.S)
    # pandoc wraps a lone image in <figure>; Confluence wants it in a paragraph or alone.
    out = re.sub(r'<figure>\s*(<ac:image.*?</ac:image>)\s*(?:<figcaption.*?</figcaption>)?\s*</figure>', r'<p>\1</p>', out, flags=re.S)
    return out, local


# ---------------------------------------------------------------- front matter

FM = re.compile(r'\A---\n(.*?)\n---\n?', re.S)


def read_md(path):
    text = path.read_text()
    m = FM.match(text)
    meta = {}
    if m:
        for line in m.group(1).splitlines():
            k, _, v = line.partition(':')
            meta[k.strip()] = v.strip()
        text = text[m.end() :]
    return meta, text


def write_md(path, meta, body):
    fm = ''.join(f'{k}: {v}\n' for k, v in meta.items())
    path.write_text(f'---\n{fm}---\n\n{body.lstrip()}')


# ---------------------------------------------------------------- commands


def page_url(base, page):
    webui = page.get('_links', {}).get('webui')
    return f'{base}/wiki{webui}' if webui else f'{base}/wiki/pages/{page["id"]}'


def cmd_pull(args):
    base, pid = parse_url(args.url)
    page = get_page(base, pid)
    out = Path(args.output) if args.output else Path(re.sub(r'[^\w.-]+', '_', page['title']).strip('_') + '.md')
    out = out.expanduser().resolve()
    rel_dir = f'asset_{out.stem}'
    atts = None

    def fetch(name, dest):
        nonlocal atts
        atts = atts if atts is not None else attachments(base, pid)
        a = atts.get(name)
        if not a:
            print(f'confluence_md: attachment {name} not found on the page', file=sys.stderr)
            return
        dest.parent.mkdir(parents=True, exist_ok=True)
        dl = a['downloadLink']
        dest.write_bytes(request('GET', f'{base}/wiki{dl}', raw=True, headers={'Accept': '*/*'}))

    storage = page['body']['storage']['value']
    body = to_markdown(storage, out.parent / rel_dir, rel_dir, fetch)
    out.parent.mkdir(parents=True, exist_ok=True)
    write_md(out, {'confluence': page_url(base, page), 'confluence_version': page['version']['number']}, f'# {page["title"]}\n\n{body}')
    print(out)
    foreign = foreign_elements(storage)
    if foreign:
        print(
            f'confluence_md: the page has Confluence-only content ({", ".join(foreign)}) not in the markdown; '
            'push will refuse to overwrite it (use append to add to the page)',
            file=sys.stderr,
        )


def split_title(body):
    """A leading `# Title` line is the page title, not part of the body."""
    m = re.match(r'\s*#\s+(.+?)\s*\n', body)
    return (m.group(1), body[m.end() :]) if m else (None, body)


def cmd_push(args):
    path = Path(args.file).expanduser().resolve()
    if not path.is_file():
        die(f'no such file: {path}')
    meta, body = read_md(path)
    if 'confluence' not in meta:
        die(f'{path} has no `confluence:` front matter (pull the page first, or use append)')
    base, pid = parse_url(meta['confluence'])
    page = get_page(base, pid)
    remote = page['version']['number']
    known = int(meta.get('confluence_version') or 0)
    if remote != known and not args.force:
        die(f'the page changed on Confluence (v{known} -> v{remote}) since this file was pulled; pull it again, or --force')
    foreign = foreign_elements(page['body']['storage']['value'])
    if foreign and not args.force:
        die(f'the page has Confluence-only content ({", ".join(foreign)}) a push would delete; use append, or --force')
    title, body = split_title(body)
    storage, images = to_storage(body, path.parent, known_image_attrs(base, page, image_names(body, path.parent)))
    if args.dry_run:
        print(storage)
        print(f'-- would upload: {[str(p) for p in images]}', file=sys.stderr)
        return
    existing = attachments(base, pid) if images else {}
    sent = [p.name for p in images if upload(base, pid, p, existing)]
    new = request(
        'PUT',
        f'{base}/wiki/api/v2/pages/{pid}',
        {
            'id': pid,
            'status': 'current',
            'title': title or page['title'],
            'body': {'representation': 'storage', 'value': storage},
            'version': {'number': remote + 1, 'message': 'Updated from markdown'},
        },
    )
    meta['confluence_version'] = new['version']['number']
    write_md(path, meta, (f'# {title}\n\n' if title else '') + body)
    print(f'v{new["version"]["number"]} {page_url(base, new)}' + (f' (uploaded {", ".join(sent)})' if sent else ''))


def cmd_append(args):
    path = Path(args.file).expanduser().resolve()
    if not path.is_file():
        die(f'no such file: {path}')
    _, body = read_md(path)
    base, pid = parse_url(args.to)
    page = get_page(base, pid)
    storage, images = to_storage(body, path.parent, known_image_attrs(base, page, image_names(body, path.parent)))
    if args.dry_run:
        print(storage)
        print(f'-- would upload: {[str(p) for p in images]}', file=sys.stderr)
        return
    existing = attachments(base, pid) if images else {}
    sent = [p.name for p in images if upload(base, pid, p, existing)]
    new = request(
        'PUT',
        f'{base}/wiki/api/v2/pages/{pid}',
        {
            'id': pid,
            'status': 'current',
            'title': page['title'],
            'body': {'representation': 'storage', 'value': page['body']['storage']['value'] + storage},
            'version': {'number': page['version']['number'] + 1, 'message': f'Appended {path.name}'},
        },
    )
    print(f'v{new["version"]["number"]} {page_url(base, new)}' + (f' (uploaded {", ".join(sent)})' if sent else ''))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('pull')
    a.add_argument('url')
    a.add_argument('-o', '--output')
    a.set_defaults(fn=cmd_pull)
    a = sub.add_parser('push')
    a.add_argument('file')
    a.add_argument('--dry-run', action='store_true')
    a.add_argument('--force', action='store_true')
    a.set_defaults(fn=cmd_push)
    a = sub.add_parser('append')
    a.add_argument('file')
    a.add_argument('--to', required=True)
    a.add_argument('--dry-run', action='store_true')
    a.set_defaults(fn=cmd_append)
    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
