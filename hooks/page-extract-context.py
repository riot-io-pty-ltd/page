#!/usr/bin/env python3
"""Extract the last ~10 readable events from a Claude Code transcript
JSONL file. Output is plain text suitable for inclusion in a phone push.

Each line is either a user message or an assistant message, optionally
including the tool calls / results that happened inside it. Long values
are truncated.
"""
import json
import sys


def extract(path: str, max_events: int = 10, tail_lines: int = 60) -> str:
    try:
        with open(path, "r") as f:
            lines = f.readlines()
    except OSError:
        return ""

    events: list[str] = []
    for line in lines[-tail_lines:]:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        t = obj.get("type")
        if t not in ("assistant", "user"):
            continue
        msg = obj.get("message", {}) or {}
        content = msg.get("content")
        if isinstance(content, list):
            parts = content
        elif content:
            parts = [{"type": "text", "text": content}]
        else:
            parts = []

        chunks: list[str] = []
        for c in parts:
            if not isinstance(c, dict):
                continue
            kind = c.get("type")
            if kind == "text" and c.get("text"):
                chunks.append(c["text"].strip())
            elif kind == "tool_use":
                name = c.get("name", "tool")
                inp = c.get("input") or {}
                short = (
                    inp.get("command")
                    or inp.get("description")
                    or inp.get("file_path")
                    or ""
                )
                if short:
                    chunks.append(f"[{name}] {short[:140]}")
            elif kind == "tool_result":
                txt = c.get("content")
                if isinstance(txt, list):
                    txt = " ".join(
                        (x.get("text") or "") for x in txt if isinstance(x, dict)
                    )
                if txt and isinstance(txt, str):
                    chunks.append(f"⤳ {txt.strip()[:120]}")

        if not chunks:
            continue
        prefix = "Claude:" if t == "assistant" else "You:"
        events.append(prefix + " " + " ".join(chunks))

    return "\n".join(events[-max_events:])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(0)
    sys.stdout.write(extract(sys.argv[1]))
