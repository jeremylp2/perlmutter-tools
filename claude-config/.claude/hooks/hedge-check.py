#!/usr/bin/env python3
"""Stop hook: block Claude from finishing a turn whose reply contains hedge/guess language.

Enforces the HARD EVIDENCE ONLY rule in ~/.claude/CLAUDE.md. Scans every assistant text block
written since the user's last typed prompt (sidechains ignored), after stripping code blocks,
inline code, double-quoted spans and '>' quote lines (so quoting a phrase does not trigger it).
Skipped when the user's prompt explicitly asks for a guess/speculation.
Blocks at most once per user prompt (no loops). Any internal error -> allow + log.
Python 3.6 compatible (system python3 on Perlmutter).
"""
import datetime
import json
import os
import re
import sys

PHRASES = [
    r"probably", r"should be", r"must be", r"most likely", r"likely", r"I think", r"I believe",
    r"presumably", r"seems like", r"appears to be", r"I'd guess", r"my guess", r"I suspect",
    r"I assume", r"assuming", r"plausibly", r"chances are", r"in all likelihood", r"almost certainly",
]
HEDGE_RE = re.compile(r"\b(" + "|".join(PHRASES) + r")\b", re.IGNORECASE)
# Skip only on an EXPLICIT request for a guess; a prompt that merely mentions guessing (e.g.
# "no guessing at all", "unless I explicitly ask for a guess") must NOT disable the check.
GUESS_ASKED_RE = re.compile(
    r"\b(your|best|educated|rough|wild|quick)\s+guess\b|\btake\s+a\s+guess\b|\bmake\s+a\s+guess\b"
    r"|\bguess\s+at\b|\bspeculate\b|\bspeculation\s+is\s+(fine|ok)\b", re.IGNORECASE)
GUESS_NEGATED_RE = re.compile(r"\b(no|not|never|don'?t|do\s+not|without|stop)\b[^.!?\n]{0,40}\bguess", re.IGNORECASE)

STATE_DIR = os.path.join(os.environ.get("SCRATCH") or os.path.expanduser("~/.cache"), "claude_hook_state")
LOG = os.path.join(STATE_DIR, "hedge_check.log")


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg))
    except Exception:
        pass


def strip_quoted(text):
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)        # fenced code
    text = re.sub(r"`[^`\n]*`", " ", text)                          # inline code
    text = re.sub(r'"[^"\n]*"', " ", text)                          # "double quoted"
    text = re.sub(u"“[^”\n]*”", " ", text)            # “curly quoted”
    text = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith(">"))
    return text


def current_turn(transcript_path):
    """Return (last typed user prompt entry, [assistant text since it])."""
    entries = []
    with open(transcript_path) as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except ValueError:
                continue
    last_user_idx, last_user = None, None
    for i in range(len(entries) - 1, -1, -1):
        e = entries[i]
        if e.get("type") == "user" and not e.get("isMeta") and not e.get("isSidechain") \
                and isinstance((e.get("message") or {}).get("content"), str):
            last_user_idx, last_user = i, e
            break
    texts = []
    for e in entries[(last_user_idx + 1 if last_user_idx is not None else 0):]:
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        for b in (e.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text":
                texts.append(b.get("text") or "")
    return last_user, texts


def main():
    raw = sys.stdin.read()
    data = json.loads(raw) if raw.strip() else {}
    sid = data.get("session_id", "unknown")
    tp = data.get("transcript_path")
    if not tp or not os.path.exists(tp):
        log("sid=%s no transcript (keys=%s) -> allow" % (sid, sorted(data)))
        return
    last_user, texts = current_turn(tp)
    prompt = (last_user or {}).get("message", {}).get("content", "") if last_user else ""
    prompt_id = (last_user or {}).get("uuid", "none")
    if GUESS_ASKED_RE.search(prompt or "") and not GUESS_NEGATED_RE.search(prompt or ""):
        log("sid=%s prompt=%s user asked for a guess -> allow" % (sid, prompt_id))
        return
    marker = os.path.join(STATE_DIR, "hedge_blocked_%s" % sid)
    try:
        already = open(marker).read().strip() == prompt_id
    except IOError:
        already = False
    if already or data.get("stop_hook_active"):
        log("sid=%s prompt=%s already blocked once this prompt (stop_hook_active=%s) -> allow"
            % (sid, prompt_id, data.get("stop_hook_active")))
        return
    hits = []
    for t in texts:
        clean = strip_quoted(t)
        for m in HEDGE_RE.finditer(clean):
            s = max(0, m.start() - 60)
            snippet = clean[s:m.end() + 60].replace("\n", " ").strip()
            hits.append("'%s' in: ...%s..." % (m.group(1), snippet))
    if not hits:
        log("sid=%s prompt=%s clean (%d text blocks) -> allow" % (sid, prompt_id, len(texts)))
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(marker, "w") as f:
        f.write(prompt_id)
    log("sid=%s prompt=%s BLOCK %d hits: %s" % (sid, prompt_id, len(hits), " | ".join(h[:80] for h in hits[:5])))
    reason = (
        "HARD EVIDENCE ONLY (CLAUDE.md): your reply this turn contains hedge/guess language:\n- "
        + "\n- ".join(hits[:10])
        + ("\n(+%d more)" % (len(hits) - 10) if len(hits) > 10 else "")
        + "\n\nFor EACH flagged claim about the state of anything: verify it now (run the command, read "
        "the file, query the source) and restate it as observed fact with its evidence, or say plainly "
        "\"I don't know\" and what would determine it. Do not just reword around these phrases. If a "
        "flagged phrase is a requirement or instruction (e.g. 'X must be run in screen') rather than a "
        "claim about state, it needs no change — say so briefly and finish."
    )
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never break the session because of this hook
        log("ERROR %s: %s -> allow" % (type(exc).__name__, exc))
    sys.exit(0)
