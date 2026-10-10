#!/usr/bin/env python3
"""PreToolUse guard (Bash, Edit, Write, MultiEdit): NEVER scope CHADO data by organism.

One organism has many proteomes, annotations and assemblies. Selecting, filtering,
joining, grouping, comparing or counting by organism_id mixes them and gives wrong
answers. Always scope by proteome: PACProteome:<pid> -> feature_dbxref -> features
(and their primary annotation / FASTA dbxref). See ~/.claude/phytozome-chado-guide.md.

Blocks (exit 2, message to Claude):
  - Bash commands containing SQL / DB code that compare organism_id (=, ==, <>, !=,
    IN, NOT IN, <=, >=) or GROUP/PARTITION/ORDER BY organism.
  - Edit/Write/MultiEdit adding the same patterns to code files (.py .sql .sh .pl .pm
    .wdl and extensionless scripts). Docs (.md .txt .rst) are exempt so the rule can be
    documented. There is no bypass.
"""
import json
import os
import re
import sys

SQLISH = re.compile(
    r"\b(select|update|delete|insert|psql|cur\.execute|session\.query|\.filter\(|"
    r"resultset|search\(|join)\b",
    re.I)
VIOLATIONS = [
    (re.compile(r"\borganism_id\b\s*(==|=|<>|!=|<=|>=|\bnot\s+in\b|\bin\b)", re.I),
     "compares organism_id"),
    (re.compile(r"(==|=|<>|!=)\s*[\w.\"']*\borganism_id\b", re.I),
     "compares against organism_id"),
    (re.compile(r"\b(group|partition|order)\s+by\b[^;]*?\borganism", re.I),
     "groups/partitions/orders by organism"),
]
CODE_EXT = {".py", ".sql", ".sh", ".pl", ".pm", ".wdl", ".bash", ""}

MSG = """BLOCKED by the NEVER-ORGANISM rule (global CLAUDE.md, phytozome-chado-guide.md): {why}.
Never select, filter, join, group, compare or count CHADO data by organism_id -- not for
queries, checks, tests, controls, scans, reports or pipeline code. One organism has many
proteomes/annotations/assemblies; organism scope silently mixes them.
Scope by PROTEOME instead:
  dbxref x JOIN db d ON d.db_id=x.db_id AND d.name='PACProteome' AND x.accession='<pid>'
  JOIN feature_dbxref fx ON fx.dbxref_id=x.dbxref_id JOIN feature f ON f.feature_id=fx.feature_id
  (annotation set: f.dbxref_id = that proteome's GFF_source dbxref; assembly: its FASTA dbxref).
Report results per proteome id, never per organism id. Also re-check any query or scan
written by someone else before using its output."""


def check(text):
    for rx, why in VIOLATIONS:
        if rx.search(text):
            return why
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    tool = data.get("tool_name", "")
    ti = data.get("tool_input", {}) or {}
    texts = []
    if tool == "Bash":
        cmd = ti.get("command", "") or ""
        if SQLISH.search(cmd):
            texts.append(cmd)
    elif tool in ("Edit", "Write", "MultiEdit"):
        path = ti.get("file_path", "") or ""
        ext = os.path.splitext(path)[1].lower()
        if ext not in CODE_EXT:
            return 0
        if tool == "Edit":
            texts.append(ti.get("new_string", "") or "")
        elif tool == "Write":
            texts.append(ti.get("content", "") or "")
        else:
            texts.extend((e or {}).get("new_string", "") or "" for e in ti.get("edits", []) or [])
    for t in texts:
        why = check(t)
        if why:
            sys.stderr.write(MSG.format(why=why) + "\n")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
