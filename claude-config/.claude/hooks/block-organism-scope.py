#!/usr/bin/env python3
"""PreToolUse guard (Bash, Edit, Write, MultiEdit): never BUNDLE CHADO feature data by organism.

One organism can have several genomes, annotations and proteome versions. Using the
organism as the scope of feature data lumps them together and gives wrong answers.
Organism is fine when the statement also pins a specific proteome / annotation /
assembly (PACProteome, a dbxref or accession compared to a value), when reading the
organism record itself, when joining to organism for its name, or when setting
organism_id on inserted features. See ~/.claude/phytozome-chado-guide.md.

Blocks (exit 2, message to Claude), only for statements that touch feature tables:
  - grouping or partitioning by organism
  - an organism_id filter with no proteome/annotation/assembly pin in the statement
Bash commands are checked when they contain SQL / DB code; Edit/Write/MultiEdit are
checked for code files (.py .sql .sh .pl .pm .wdl, extensionless). Docs are exempt.
"""
import json
import os
import re
import sys

SQLISH = re.compile(
    r"\b(select|update|delete|insert|psql|cur\.execute|session\.query|\.filter\(|"
    r"resultset|search\()", re.I)
FEATURE_TABLES = re.compile(
    r"\b(feature|featureloc|featureprop|featurepropjson|feature_relationship|"
    r"feature_dbxref|feature_residues|feature_cvterm|analysisfeature)\b", re.I)
GROUP_BY_ORG = re.compile(r"\b(group|partition)\s+by\b[^;]*?\borganism", re.I)
# organism_id compared to a value / parameter / list -- not to another organism_id
# column (a join to read the organism's attributes is fine).
ORG_FILTER = re.compile(
    r"\borganism_id\b\s*(?:(?:==|=|<>|!=)\s*(?![\w.\"'`]*organism_id\b)\S"
    r"|(?:not\s+)?in\s*\()", re.I)
# Something in the same statement that pins ONE proteome / annotation / assembly.
PIN = re.compile(
    r"PACProteome|proteome_id|\bdbxref_id\b\s*(?:==|=|\bin\b|=\s*any)\s*\S|"
    r"\baccession\b\s*(?:==|=|\bin\b)\s*\S|annotation_dbxref|assembly_dbxref", re.I)
CODE_EXT = {".py", ".sql", ".sh", ".pl", ".pm", ".wdl", ".bash", ""}

MSG = """BLOCKED: this {where} bundles CHADO feature data by organism ({why}).
One organism can have several genomes / annotations / proteome versions; organism scope
lumps them together. Pin the specific proteome instead (PACProteome:<pid> -> feature_dbxref
-> features; annotation = its GFF_source dbxref, assembly = its FASTA dbxref), or add that
pin alongside the organism condition. Organism is fine for reading the organism record,
joining for its name, setting organism_id on inserts, or alongside a proteome pin.
Report per proteome, never organism totals as proteome results."""


def statements(text):
    return [s for s in re.split(r";\s*(?:\n|$)", text) if s.strip()]


def check(text):
    for st in statements(text):
        if not FEATURE_TABLES.search(st):
            continue
        if GROUP_BY_ORG.search(st):
            return "groups/partitions feature data by organism"
        if ORG_FILTER.search(st) and not PIN.search(st):
            return "filters feature data by organism with no proteome/annotation/assembly pin"
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
        ext = os.path.splitext(ti.get("file_path", "") or "")[1].lower()
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
            sys.stderr.write(MSG.format(where="command" if tool == "Bash" else "edit", why=why) + "\n")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
