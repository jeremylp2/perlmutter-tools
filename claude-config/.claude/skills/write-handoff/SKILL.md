---
name: write-handoff
description: Write a session handoff / state / resume doc to a rigorous, complete bar. Use whenever the user asks for a handoff, a state doc, "write down everything," or when preparing for a compaction — so a fresh session with ZERO prior context can continue correctly without rediscovering anything or being misled by stale artifacts. Triggers on "write a handoff", "handoff to the quality bar", "prepare to compact", "write down everything about this session".
---

# Write a handoff to the quality bar

When this skill is called, STOP. **The VERY FIRST tool call you make MUST be the Write that creates the
handoff file — literally nothing before it.** No Bash, no Read, no Grep, no `kubectl`/`curl`/`git`, no
status check, no "quick capture" of in-flight state, no verification, no finishing whatever you were
mid-way through. ZERO other tool calls first. "Drop everything" is absolute and literal.

If you feel the urge to check one thing first — a log, a job's status, a count, "just confirm X" — that
urge is the failure this rule exists to stop: **DO NOT run it.** Write it into the handoff as "was
running / value uncertain at handoff — RE-VERIFY with `<command>`" instead. Gathering and confirming
state is the NEXT session's job (that is what the re-verify commands are for); YOUR job here is to get
everything you ALREADY know onto disk before the context is lost. A fact you would have to run a command
to learn was not going to survive the compaction anyway — record the pointer, not the value.

The ONLY tool calls permitted before the handoff file exists are: (a) writing the handoff file itself, and
(b) writing a permanent guide/memory for a recurring procedure that would otherwise be lost (MANDATORY
FIRST, below) — composed from what you already know, not from fresh investigation. Reading a file to help
write such a guide is the sole allowed exception, and only when the guide's correctness depends on it.
Anything else — any information-gathering, any progress on the underlying task — done before the handoff
file is on disk is a violation of this skill.

Produce a handoff that lets a fresh session with **zero prior context** act correctly without
rediscovering anything or being misled. It is NOT done unless it meets ALL 12 points below, then passes a
completeness sweep. This bar exists because thin handoffs cost real hours: fresh sessions kept testing
STALE deployments and trusted DERIVED claims as fact.

## THE GOVERNING PRINCIPLE (this is the whole job)

**Compaction wipes in-context memory. The handoff's ENTIRE purpose is that nothing core, critical, or
recurring survives only in that wiped memory. If any such knowledge can plausibly be lost at the next
compaction, THE HANDOFF HAS FAILED — no matter how polished the rest is.** Judge everything below against
this one test: *"after the next compact, can the work continue correctly and can every recurring action be
redone — from durable artifacts alone?"* If the honest answer is no, you are not done.

This has a crucial corollary the rest of the skill operationalizes: **durable knowledge has two homes, and
you must route each fact to the right one.** *Session state* (what's live, what's pending, decisions,
in-flight ops) goes in the handoff doc. *Reusable/recurring procedures* (how to redeploy, how a service
picks up config, build/rollout recipes, operational fixes) go in PERMANENT guides/memory — because the
handoff itself is ephemeral and will be gone in a session or two. Knowledge that is core enough to be
catastrophic if forgotten, yet lives only somewhere ephemeral, is the exact failure this skill exists to
prevent.

**Where to write it:** a NON-repo path (e.g. `$SCRATCH`, or a non-git shared dir). NEVER commit a handoff
to git — that is a cardinal rule (session/handoff/operational docs never enter any repo, any branch).

## MANDATORY FIRST: extract recurring PROCEDURES into PERMANENT guides — the handoff is NOT their home

A handoff is EPHEMERAL and per-session; compaction wipes in-context procedural memory **by design**. So a
reusable, recurring procedure that lives ONLY in the handoff (or only in the model's head) is **LOST at the
next compaction** — even a flawless handoff cannot save it, because a handoff captures *this session's
state*, not *how to do a recurring thing*. This has already burned real work (a critical dev-frontend
redeploy procedure, done many times, evaporated at a compaction because it was never written to a guide).

Before finishing the handoff you MUST do this pass — it ranks EQUAL with getting live state right:

- **Identify every critical recurring procedure** used, relied on, or (re)discovered this session that is
  NOT already written in a permanent guide/memory. Test: *"if a future session had to DO this again, could
  it, from the permanent guides/memories alone?"* Qualifiers include — how a service picks up its config,
  a redeploy / rollout / build+push+digest sequence, an operational fix recipe, a non-obvious
  endpoint/param/flag, an env or reachability quirk, a DB write pattern, a "which of N look-alikes is live"
  rule.
- **Write each into a DURABLE home IMMEDIATELY** — a guide in the stow repo (per the global rule:
  `~/gh/perlmutter-tools/claude-config/.claude/...`, then `stow`) and/or a memory file with a `MEMORY.md`
  pointer. NEVER leave it only in the handoff. The handoff then POINTS to that guide by path.
- **A handoff that references (or relies on) a procedure that exists nowhere permanent is a DEFECT.** Fix it
  before the handoff is considered done. If you catch yourself writing "as we've done before" or "the usual
  redeploy" without a guide path to cite, STOP and write the guide first.

## STATE (get the facts right; kill stale-vs-live confusion)

1. **LIVE STATE FIRST.** Open with "What is live right now." For EVERY component give its exact identity —
   never vague ("it's on SPIN"): app/endpoint → public URL + which cluster + **which kubeconfig file** +
   namespace + deployment/pod + image **digest**; datastore/index/store → name + host/path + **current**
   exact size/count measured THIS session; router/proxy/config → exactly what points to what.
2. **LIVE vs STALE — explicit.** List EVERY look-alike / old version / decoy / superseded resource that is
   NOT live, each with a one-line "ignore because…". If there are multiple ES/DB/store/deployments, name
   the ONE authoritative one and mark the rest DEAD.
3. **VERIFIED vs ASSUMED — label every claim.** Tag each fact VERIFIED (exact command run + what it
   returned + date) or ASSUMED/INFERRED (flagged needs-check). NEVER state a derived conclusion ("X = Y",
   "this snapshot is the live index", "the process is running") as fact without evidence + when checked.
   Anything not verified THIS session = stale-until-rechecked.
4. **HOW TO RE-VERIFY.** Exact commands to confirm each live component's current state (kubeconfig export,
   port-forward, curl, counts) so the next session never reconstructs them. Include access/auth specifics
   WITHOUT secrets: where each credential/token/kubeconfig lives and how to auth.
5. **PROVENANCE.** Where each thing came from + why, and any known config regressions / expedient choices
   that create traps.
6. **KNOWN ERRORS / UNCERTAINTIES / OPEN QUESTIONS.** Stated plainly; never buried or omitted.
7. **DOCKET.** Ordered pending work, each item with enough detail to start.

## CONTINUITY (a compaction handoff is broader than a state doc; losing these breaks the next session)

8. **USER DIRECTIVES & DECISIONS** (highest-value — put near the top). Every explicit instruction,
   constraint, preference, and decision the user made this session, WITH the reasoning and any REJECTED
   alternatives — so nothing is re-litigated or violated.
9. **IN-FLIGHT OPERATIONS.** Anything running/pending NOW (background jobs, screens, snapshots, long tasks):
   what it is, WHERE (host / PID / logfile / screen name / task-id), how to check status, expected
   completion, and what to do on success AND on failure.
10. **SESSION ARTIFACTS.** Every file/script/data product created or modified — exact paths + one-line
    purpose. Include edited source files + the git branch.
11. **THE TASK & EXACT REPRO.** The concrete problem being solved, with real repro inputs + expected vs
    actual output, so a fix can be reproduced and verified.
12. **"YOU ARE HERE."** The single immediate next action, and what was mid-way through at the compact.

## Completeness sweep (the real "nothing forgotten" step — do it every time)

After writing, RE-READ the session start-to-finish and explicitly ask: "what did I do, decide, learn,
break, or leave running that isn't captured above?" Add whatever's missing. A checklist guarantees the
right categories are covered, not that every detail was remembered — this sweep catches the straggler.

Also explicitly ask: **"what recurring PROCEDURE did I use or discover that a future session must be able
to redo — and is it in a PERMANENT guide/memory, not just this handoff?"** If any isn't, write the guide
NOW (see MANDATORY FIRST above). A procedure captured only here is a procedure lost at the next compaction.

Every single thing you've learned in the session, everything done in the session, everything about current
state, everything that lead up to that state, everything about pending and future jobs should all be there. 
Err heavily on the side of writing too much. Allow nothing to be forgotten. Nothing. 

## Close — DOC vs LIVE CHAT (keep these separate)

**In the handoff DOC:** end it by naming, one line each, the THREE most dangerous things a fresh session
could get wrong. (The doc contains points 1–12 + these three.)

**In the LIVE CHAT reply to the user (NOT written into the doc):** after writing the file, send the user, in
the conversation:
- the path the handoff was written to, and
- a ready-to-paste **POST-COMPACT RESUME INSTRUCTION** as its own clearly-marked block ("**After compact,
  paste this:**"). It lives in the chat — NOT in the doc — because the user must have it in-hand to paste
  back after the compact wipes context; a copy buried in the file is useless to them at that moment.

The post-compact resume instruction must tell the next session to:
1. **Read the handoff in full** at its exact path (and any docs it points to, in order).
2. **Re-verify current state** before acting (per the handoff's re-verify commands) — trust nothing as
   still-true without checking; in-flight operations may have finished or failed.
3. Pick up at **"YOU ARE HERE"** — the single immediate next action.
4. **Do nothing destructive or state-changing without explicit confirmation**, honoring the recorded USER
   DIRECTIVES.
Keep it short enough to paste in a line or few, specific to THIS session (real path, real next action, real
live operation to check first).
