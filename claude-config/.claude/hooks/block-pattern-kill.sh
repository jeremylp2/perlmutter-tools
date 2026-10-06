#!/bin/bash
# PreToolUse(Bash) guard — RULE ZERO: block pattern-based process killing/matching.
# `pkill`, `killall`, `pgrep -f/--full`, and `... | xargs kill` match the Bash tool's own `bash -c '<cmd>'`
# wrapper (the pattern is in its command line) and have killed Claude's shell countless times.
# Exit 2 = block; stderr is shown to Claude.
CMD=$(jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0
if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_./-])(pkill|killall)([^[:alnum:]_-]|$)|(^|[^[:alnum:]_./-])pgrep[[:space:]]+([^|;&]*[[:space:]])?(-[[:alpha:]]*f[[:alpha:]]*|--full)([[:space:]]|$)|xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+kill([[:space:]]|$)'; then
  cat >&2 <<'MSG'
BLOCKED by RULE ZERO (global CLAUDE.md): pkill / killall / pgrep -f / xargs kill are banned.
They match this tool's own `bash -c` wrapper and kill Claude's shell. Kill ONLY by a PID recorded at launch:
  cmd & PID=$!; ...; kill "$PID"          (same command)
  PID=$$ on line 1 of the job log  ->  pid=$(grep -o 'PID=[0-9]*' LOG | head -1 | cut -d= -f2); kill -0 "$pid" && kill "$pid"
  echo $! > /path/x.pid  ->  kill "$(cat /path/x.pid)"
Check liveness with `kill -0 <PID>` / `ps -o pid,args -p <PID>`, log lines, or output files.
MSG
  exit 2
fi
exit 0
