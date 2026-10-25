#!/usr/bin/env python3
"""Recent-activity context for a Page push, from a Claude Code transcript.

    page-extract-context.py [--max-events N] [--max-chars N] [--tool-output] TRANSCRIPT
    page-extract-context.py --redact            (filters stdin -> stdout)

Prints the last few readable events of a transcript JSONL file as plain
text, one event per line ("You: ...", "Claude: ...", "[Bash] ..."), oldest
first, so the phone shows what Claude was just doing rather than only the
bare alert.

Design constraints, all learned the hard way:
  - Transcripts grow to many MB (whole files and base64 images inline), so
    we walk the file backwards from the END, stop as soon as we have enough
    events, and skip giant single lines without buffering them, instead of
    readlines() on the whole thing. A hook must never stall Claude.
  - This runs inside a hook: it must never crash, never block (refuses
    FIFOs and other non-regular files) and always exits 0. Any failure
    just means "no context".
  - The text leaves the machine (Worker history, lock-screen push), so
    tool output is omitted unless --tool-output is passed, and obvious
    secrets (KEY=value, bearer tokens, PEM blocks, well-known key formats)
    are redacted best-effort. Redaction is a safety net, not a guarantee.
"""
import json
import os
import re
import stat
import sys

# Upper bound on how far back from the end we'll scan, and on the size of
# a single line we'll parse. Lines longer than MAX_LINE_BYTES are almost
# always images or huge tool results (no readable text for a phone), so
# they're skipped without being held in memory.
MAX_SCAN_BYTES = 16 * 1024 * 1024
MAX_LINE_BYTES = 512 * 1024
BLOCK = 64 * 1024

DEFAULT_MAX_EVENTS = 8
DEFAULT_MAX_CHARS = 1500
PER_EVENT_CHARS = 300

_SECRET_PATTERNS = [
    # PEM private keys (multi-line, so collapse the whole block).
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|$)", re.S),
     "[redacted private key]"),
    # Authorization headers / bearer tokens.
    # "Basic"/"token" are ordinary words too ("basic configuration"), so
    # their value must look like a credential: contain a digit or +/=.
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"), r"\1 [redacted]"),
    (re.compile(r"(?i)\b(basic|token)\s+(?=[A-Za-z0-9._~+/=-]*[0-9+/=])[A-Za-z0-9._~+/=-]{12,}"), r"\1 [redacted]"),
    # NAME=value / NAME: value where NAME looks secret-ish.
    (re.compile(r"(?i)\b([A-Z0-9_.-]*(?:api[_-]?key|secret|token|passw(?:or)?d|pwd|credential|private[_-]?key|access[_-]?key)[A-Z0-9_.-]*)"
                r"([\"']?\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|[^\s\"',;]{6,})"),
     r"\1\2[redacted]"),
    # URLs with inline credentials: scheme://user:pass@host
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/:@]+:[^\s/@]+@"), r"\1[redacted]@"),
    # Well-known key formats.
    (re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"), "[redacted]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "[redacted]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "[redacted]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "[redacted]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[redacted]"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"), "[redacted]"),
]

# Claude Code wraps harness-injected text in tags; it's noise on a phone.
_HARNESS_BLOCK = re.compile(
    r"<(system-reminder|command-message|command-args|local-command-stdout|local-command-stderr)>.*?</\1>",
    re.S,
)
_WS = re.compile(r"\s+")


def redact(text):
    for pattern, repl in _SECRET_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def _clean(text, limit):
    text = _HARNESS_BLOCK.sub(" ", text)
    text = _WS.sub(" ", text).strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def reverse_lines(path, max_scan=MAX_SCAN_BYTES, max_line=MAX_LINE_BYTES):
    """Yield the complete lines of `path`, newest first.

    Reads backwards in BLOCK-sized chunks, so cost is proportional to how
    far back the caller keeps iterating (capped at `max_scan` bytes), not
    to the file size. Lines longer than `max_line` are skipped.
    """
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        return
    with open(path, "rb") as f:
        pos = f.seek(0, os.SEEK_END)
        scanned = 0
        buf = b""
        # True while we're inside an oversized line whose tail we dropped.
        skipping = False
        while pos > 0 and scanned < max_scan:
            step = min(BLOCK, pos)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + buf
            scanned += step
            parts = buf.split(b"\n")
            buf = parts[0]
            for line in reversed(parts[1:]):
                if skipping:
                    # Head of the oversized line: its start is now known.
                    skipping = False
                    continue
                if line.strip():
                    yield line
            if len(buf) > max_line:
                buf = b""
                skipping = True
        if pos == 0 and not skipping and buf.strip():
            yield buf


def _tool_use_summary(c):
    name = c.get("name") or "tool"
    inp = c.get("input")
    if not isinstance(inp, dict):
        inp = {}
    for key in ("command", "description", "file_path", "notebook_path", "pattern", "url", "query", "path"):
        val = inp.get(key)
        if val:
            return "[%s] %s" % (name, val if isinstance(val, str) else json.dumps(val))
    return None


def _tool_result_text(c):
    txt = c.get("content")
    if isinstance(txt, list):
        txt = " ".join(
            x.get("text") or "" for x in txt if isinstance(x, dict) and isinstance(x.get("text"), str)
        )
    return txt if isinstance(txt, str) else ""


def event_text(obj, include_tool_output=False):
    """One readable line for a transcript entry, or None to skip it."""
    if not isinstance(obj, dict):
        return None
    t = obj.get("type")
    if t not in ("assistant", "user"):
        return None
    # Meta entries (harness bookkeeping) and subagent sidechains aren't
    # part of the conversation the human is following.
    if obj.get("isMeta") or obj.get("isSidechain"):
        return None
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return None
    content = msg.get("content")
    if isinstance(content, str):
        parts = [{"type": "text", "text": content}]
    elif isinstance(content, list):
        parts = content
    else:
        return None

    chunks = []
    only_tool_results = True
    for c in parts:
        if isinstance(c, str):
            c = {"type": "text", "text": c}
        if not isinstance(c, dict):
            continue
        kind = c.get("type")
        if kind == "text" and isinstance(c.get("text"), str):
            only_tool_results = False
            text = _clean(c["text"], PER_EVENT_CHARS)
            if text:
                chunks.append(text)
        elif kind == "tool_use":
            only_tool_results = False
            summary = _tool_use_summary(c)
            if summary:
                chunks.append(_clean(summary, 160))
        elif kind == "tool_result":
            if include_tool_output:
                text = _clean(_tool_result_text(c), 120)
                if text:
                    chunks.append("⤳ " + text)
        else:
            only_tool_results = False

    if not chunks:
        return None
    if t == "assistant":
        prefix = "Claude:"
    elif only_tool_results:
        # Tool results arrive as "user" entries, but the human didn't say them.
        prefix = "Output:"
    else:
        prefix = "You:"
    return redact(_clean(prefix + " " + " ".join(chunks), PER_EVENT_CHARS + 20))


def extract(path, max_events=DEFAULT_MAX_EVENTS, max_chars=DEFAULT_MAX_CHARS, include_tool_output=False):
    if max_events <= 0:
        return ""
    events = []
    try:
        for raw in reverse_lines(path):
            try:
                obj = json.loads(raw.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            line = event_text(obj, include_tool_output)
            if line:
                events.append(line)
                if len(events) >= max_events:
                    break
    except (OSError, ValueError):
        pass
    events.reverse()
    # Trim from the oldest end: the newest events matter most.
    while events and len("\n".join(events)) > max_chars:
        if len(events) == 1:
            events[0] = events[0][: max(0, max_chars - 1)].rstrip() + "…"
            break
        events.pop(0)
    return "\n".join(events)


def _int_arg(value, default):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default


def main(argv):
    max_events = DEFAULT_MAX_EVENTS
    max_chars = DEFAULT_MAX_CHARS
    include_tool_output = False
    path = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--redact":
            data = sys.stdin.buffer.read(1024 * 1024).decode("utf-8", errors="replace")
            sys.stdout.write(redact(data))
            return
        if arg == "--max-events" and i + 1 < len(argv):
            max_events = _int_arg(argv[i + 1], max_events)
            i += 2
            continue
        if arg == "--max-chars" and i + 1 < len(argv):
            max_chars = _int_arg(argv[i + 1], max_chars)
            i += 2
            continue
        if arg == "--tool-output":
            include_tool_output = True
        elif not arg.startswith("--"):
            path = arg
        i += 1
    if path:
        sys.stdout.write(extract(path, max_events, max_chars, include_tool_output))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException:  # noqa: BLE001 — a hook helper must never fail loudly
        pass
    sys.exit(0)
