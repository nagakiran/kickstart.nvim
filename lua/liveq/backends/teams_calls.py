"""The call history the Teams desktop app (new Teams) keeps on disk, for liveq's Teams backend.

    python3 -I teams_calls.py DIR      DIR: the app's IndexedDB LevelDB directory (https_teams.microsoft.com_0...)

Prints a JSON array of calls, one object each: id, start, connect, end (ISO times; connect is null for a call never
answered), dir (incoming|outgoing), type (twoParty|multiParty), state (accepted|missed), thread (the chat of a group
call), people ([{u: user id, n: name or null}], everyone on the call, you included).

Graph strips the call log (thread 48:calllogs) to each call's id, but the app caches the whole record as the JSON
property `call-log` of each log message. This reads the LevelDB tables and write-ahead log directly (Snappy and all,
standard library only), finds those properties and decodes them, without parsing the V8-serialized values around them.
Read-only: the files are only opened for reading, so the app may keep running.
"""

import json
import os
import sys


def varint(buf, pos):
    n = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if b < 0x80:
            return n, pos


def unsnappy(buf):
    """Decompresses a raw Snappy block."""
    _, pos = varint(buf, 0)
    out = bytearray()
    while pos < len(buf):
        tag = buf[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:  # literal
            n = tag >> 2
            if n >= 60:
                width = n - 59
                n = int.from_bytes(buf[pos : pos + width], "little")
                pos += width
            n += 1
            out += buf[pos : pos + n]
            pos += n
            continue
        if kind == 1:
            n, off = ((tag >> 2) & 7) + 4, ((tag >> 5) << 8) | buf[pos]
            pos += 1
        elif kind == 2:
            n, off = (tag >> 2) + 1, int.from_bytes(buf[pos : pos + 2], "little")
            pos += 2
        else:
            n, off = (tag >> 2) + 1, int.from_bytes(buf[pos : pos + 4], "little")
            pos += 4
        start = len(out) - off
        if off >= n:
            out += out[start : start + n]
        else:  # the copy overlaps what it writes
            for i in range(n):
                out.append(out[start + i])
    return bytes(out)


def read_block(data, off, size):
    raw = data[off : off + size]
    return unsnappy(raw) if data[off + size] == 1 else raw


def block_values(block):
    restarts = int.from_bytes(block[-4:], "little")
    end = len(block) - 4 - 4 * restarts
    pos = 0
    while pos < end:
        _, pos = varint(block, pos)
        unshared, pos = varint(block, pos)
        size, pos = varint(block, pos)
        pos += unshared
        yield block[pos : pos + size]
        pos += size


def table_blocks(path):
    """The data blocks of a LevelDB table (.ldb), decompressed."""
    with open(path, "rb") as f:
        data = f.read()
    footer = data[-48:]
    _, p = varint(footer, 0)
    _, p = varint(footer, p)
    index_off, p = varint(footer, p)
    index_size, _ = varint(footer, p)
    for handle in block_values(read_block(data, index_off, index_size)):
        off, q = varint(handle, 0)
        size, _ = varint(handle, q)
        yield read_block(data, off, size)


def log_records(path):
    """The records of a LevelDB write-ahead log (.log): 32KB blocks of fragments with 7-byte headers."""
    with open(path, "rb") as f:
        data = f.read()
    pos, record = 0, b""
    while pos + 7 <= len(data):
        left = 32768 - pos % 32768
        if left < 7:
            pos += left
            continue
        size, kind = int.from_bytes(data[pos + 4 : pos + 6], "little"), data[pos + 6]
        fragment = data[pos + 7 : pos + 7 + size]
        pos += 7 + size
        if kind == 0:
            pos += 32768 - pos % 32768 if pos % 32768 else 0
            continue
        record = fragment if kind in (1, 2) else record + fragment
        if kind in (1, 4):
            yield record
            record = b""


NEEDLES = (("latin-1", b"call-log"), ("utf-16-le", "call-log".encode("utf-16-le")))
DECODER = json.JSONDecoder()


def call_logs(buf, found):
    """Adds the `call-log` objects in `buf` to `found` (by call id). V8 keeps a string as Latin-1 bytes, or UTF-16
    when it has other characters (a name in another script)."""
    for encoding, needle in NEEDLES:
        i = buf.find(needle)
        while i >= 0:
            text = buf[i : i + 30000].decode(encoding, "replace")
            j = text.find("{", 0, 40)
            if j >= 0:
                try:
                    obj, _ = DECODER.raw_decode(text[j:])
                    if isinstance(obj, dict) and obj.get("callId"):
                        found[obj["callId"]] = obj
                except ValueError:
                    pass
            i = buf.find(needle, i + 1)


def user(identity):
    """`8:orgid:<id>` -> <id>; None for anything else (a phone number, a bot)."""
    if isinstance(identity, str) and identity.startswith("8:orgid:"):
        return identity[len("8:orgid:") :]
    return None


def trim(c):
    people, seen = [], set()

    def add(ident, name=None):
        u = user(ident)
        key = u or ident
        if key and key not in seen:
            seen.add(key)
            people.append({"u": u, "n": name or (None if u else ident)})
        elif key and name:
            for p in people:
                if (p["u"] or p["n"]) == key and not p["n"]:
                    p["n"] = name

    for side in ("originatorParticipant", "targetParticipant"):
        p = c.get(side) or {}
        add(p.get("id"), p.get("displayName"))
    for p in c.get("participantList") or []:
        add(p.get("id"), p.get("displayName"))
    for ident in c.get("participants") or []:
        add(ident)
    return {
        "id": c["callId"],
        "start": c.get("startTime"),
        "connect": c.get("connectTime"),
        "end": c.get("endTime"),
        "dir": c.get("callDirection"),
        "type": c.get("callType"),
        "state": c.get("callState"),
        "thread": c.get("threadId"),
        "people": people,
    }


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: teams_calls.py DIR (the Teams IndexedDB LevelDB directory)")
    root, found = sys.argv[1], {}
    # oldest files first, so a newer copy of a record wins
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        try:
            if name.endswith(".ldb"):
                for block in table_blocks(path):
                    call_logs(block, found)
            elif name.endswith(".log"):
                for record in log_records(path):
                    call_logs(record, found)
        except (OSError, IndexError, ValueError):
            continue  # a file compacted away or half-written while reading: the rest still counts
    json.dump([trim(c) for c in found.values()], sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
