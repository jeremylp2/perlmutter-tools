# File Watchers on GPFS/CFS (and Lustre/NFS) — why inotify dies and how to get a real fast watcher

**TL;DR:** NERSC **CFS is GPFS**, and **GPFS delivers NO inotify events** — not even for a write made
on the *same* node. Every inotify-based watcher (Vite/rollup `build --watch`, webpack, `chokidar`'s
default, `nodemon`'s default, `fs.watch`) is therefore **dead on arrival** when watching a CFS path.
Polling *can* work because `stat()`/mtime **does** update on CFS, but most tools' polling flags are
unreliable (rollup 4 ignores `CHOKIDAR_USEPOLLING`). **The robust fix is to watch a NODE-LOCAL copy
(container overlay / real ext4/tmpfs, where inotify works) and poll-sync the CFS source into it with
`cp -u` (stat-based).** Proven end-to-end: a CFS edit shows up in the served app in ~3s.

This bit us repeatedly in the `pfam-universal` sandbox (SPIN `pfam-sandbox`, source on CFS at
`/global/cfs/cdirs/plant/xdomain_pfam/sandbox/pfam-search`). See [[spin-helm-guide]].

---

## The facts (all empirically verified)

1. **inotify does not fire on CFS/GPFS at all.** A `vite build --watch` (or nodemon, or a bare
   chokidar watcher) pointed at a CFS dir never rebuilds on edits — even when the edit is made from the
   *same login node* the watcher runs on. GPFS/Lustre/NFS don't implement the fsnotify hooks inotify
   needs. So "run the watcher on the login node next to my edits" **does not help** — same-FS inotify
   is still dead.
2. **`stat()`/mtime DOES update on CFS**, cross-node, within ~1s. `stat -c %y file` reflects an edit
   made from another node. So *polling by mtime* is viable — the change is detectable, just not via
   inotify events.
3. **Most tools' "use polling" flags are unreliable here.** `CHOKIDAR_USEPOLLING=1` /
   `{ chokidar: { usePolling: true } }` in `vite.config` had NO effect on Vite 5 / rollup 4's
   `build --watch` (rollup's build watcher doesn't honor it). `nodemon --legacy-watch` uses
   `fs.watchFile` polling and *sometimes* detects CFS changes but was not dependable in testing.
4. **inotify WORKS on a node-local filesystem** — a container's overlay layer, `/tmp` (tmpfs/overlay),
   or a real ext4 volume. So a watcher over a node-local copy rebuilds instantly and natively.

## The solution: node-local copy + stat-poll sync

Run the frontend build-watch + server nodemon on a **node-local** working copy inside the pod, and a
tiny **1-second `cp -u` poll** that syncs the CFS source into it. Because `cp -u` compares mtimes
(which update on CFS) and writes to the *node-local* copy, the local write triggers **native inotify**
→ the watcher rebuilds within ~1–2s. CFS stays the source of truth (edit it from anywhere, persistent);
the node-local copy is ephemeral (reseeded on pod restart).

Reference implementation: **`~/git/pfam-search/dev-watch.sh`** (also at the sandbox source root). Shape:

```bash
SRC=/app                 # CFS-mounted source (read)
LOCAL=/tmp/dev-src       # NODE-LOCAL (container overlay) — inotify works here
# seed node-local copy (symlink node_modules from CFS; don't copy dist)
cp -a "$SRC"/*.js "$SRC"/*.json "$SRC"/*.html "$LOCAL"/;  cp -a "$SRC/src" "$SRC/public" "$SRC/server" "$LOCAL"/
ln -sfn "$SRC/node_modules" "$LOCAL/node_modules";  cd "$LOCAL"
# stat-based poll: CFS -> node-local (the ONLY thing that detects CFS edits). cp -u = copy if src newer.
( while true; do cp -ru "$SRC/src/." "$LOCAL/src/"; cp -ru "$SRC/public/." "$LOCAL/public/";
                 cp -ru "$SRC/server/." "$LOCAL/server/"; cp -u "$SRC"/*.js "$SRC"/*.html "$LOCAL"/; sleep 1; done ) &
npx vite build                                        # initial
exec npx concurrently -k -n build,server \
  "npx vite build --watch" \                          # inotify on $LOCAL → real rebuilds
  "npx nodemon server.js"                             # inotify on $LOCAL → real restarts
```

Wire it as the pod's dev command (SPIN devMode): container `args` →
`npm install ... && exec bash /app/dev-watch.sh`. (A live `kubectl patch` works but is lost on
`helm upgrade` — fold it into the chart's devMode command for durability.)

## Verifying a watcher — do NOT trust the build log

The `[build] built in 2633ms` line **repeats verbatim** and is often the *stale initial build* — it
misled me into "verifying" a watcher that wasn't firing, multiple times. The **only** trustworthy test
is an observable end-to-end change:
- Make a **real, visible source edit** (a user-facing string — NOT a comment; comments are minified away
  so the bundle hash won't change).
- Confirm the **served output** changed: `curl <app>/ | grep -o 'index-[A-Za-z0-9]*\.js'` before/after,
  and `curl <app>/assets/<bundle>` and grep for the edited string. The hash must change and the new
  bundle must contain the edit.

## Rules of thumb

- **Never** expect inotify to work on CFS/GPFS/Lustre/NFS. Watch a node-local copy; poll-sync the
  network FS into it by mtime.
- Prefer a **dumb `cp -u`/`stat` poll** over a tool's built-in "polling" flag — the flags are often
  ignored (rollup 4) or flaky.
- `/tmp` inside a **container** is fine and correct for this (node-local overlay) — that is NOT the
  "never use /tmp on Perlmutter" rule, which is about Perlmutter's host filesystems.
- Editing directly *in the pod* (node-local) also works, but then you must sync back to CFS for
  persistence; the CFS-source-of-truth + poll-INTO-local direction avoids any data-loss risk.
