# Building large Elasticsearch indexes FAST (multi-node, dori/SLURM) — lessons with measured numbers

Source: Pfam rebuild 2026-09-23 (443,949,127 protein docs + 655,469,985 per-hit docs, ES 9.2.1, dori). Every number below
was measured in that session. Scripts (reference implementation):
`/pscratch/sd/p/phillips/rebuild_20260923/{build.sbatch,build_shm.sbatch,es_node.sh,es_node_shm.sh,load_index.py,fetch_restore.sh}`
(copies on dori: `/clusterfs/jgi/scratch/science/wcplant/jlphillips/pfam-rebuild-20260923/rebuild/`).

## 0. BEFORE creating the index — decide everything that cannot change later
- **`index.sort` is fixed at creation.** ES early-terminates a sorted query ONLY if the query's sort EQUALS the index sort
  (the index sort is a prefix-match: query sort [evalue] on index sort [evalue] works; adding a tie-breaker to the QUERY
  that is not in the index sort kills early termination: ~0.5 s -> ~2.5 s measured on prod). If you need a deterministic
  tie-break (you do, for paging/search_after/download-order parity), put the WHOLE chain in index.sort, e.g.
  `index.sort.field: [evalue, domain, genome_id, protein_id]`, all asc, and send exactly that sort.
  (Mistake 2026-09-23: built with index.sort=[evalue] only -> restart.)
- **Write down every query the index must serve** (every sort column, both directions, multi-term collapse, counts) and
  check each against the mapping + index.sort BEFORE loading. A tiny functional test does NOT catch this.
- Numeric precision: `float` cannot hold e-values like 6.8e-240 (min ~1.4e-45) -> use `double` for any sort/filter field.
- Shard count = parallelism during the build AND per-query fan-out when served (prod single node, 4 CPU: keep modest; 12 used).

## 1. Cluster layout on SLURM (dori: 64 cores, ~503 GB RAM, 252 GB /dev/shm per node; QOS jgi_normal max 50 nodes/user)
- One ES node per SLURM node; shards == nodes (`index.routing.allocation.total_shards_per_node = ceil(shards/nodes)`).
- Build separate indexes on SEPARATE clusters/jobs in parallel (different cluster.name + http/transport ports).
- `srun --overlap --ntasks-per-node=1 -c 32 es_node.sh` for ES and `srun --overlap ... -c 30 loader` for loaders.
  **NEVER `-c 1`**: SLURM confines the step to that many cores -> ES + all loader procs on ONE core
  (measured 127k docs/s vs 349k-944k after the fix; write pool active=1, java 76% CPU on a 64-core node).
- Per-node settings that are REQUIRED on dori:
  - `ES_PATH_CONF` = a PRIVATE copy of config/ per node (shared ES_HOME/config on NFS -> nodes race creating
    `elasticsearch.keystore.tmp` -> FileAlreadyExistsException, exit 74).
  - `vm.max_map_count` is 65530 -> `-E node.store.allow_mmap=false` (bootstrap checks are enforced once bound to a
    non-loopback address).
  - `ulimit -n 131072` (soft limit is 1024, hard 131072).
  - `-E cluster.routing.allocation.disk.threshold_enabled=false` (VAST scratch sits at ~90% used).
  - `-E xpack.security.enabled=false -E xpack.ml.enabled=false -E bootstrap.memory_lock=false`, heap `-Xms31g -Xmx31g`,
    `indices.memory.index_buffer_size=40%`, `thread_pool.write.queue_size=20000`.
  - `/local` is root-owned on dori (not usable).
- **Data dir: RAM (/dev/shm), not VAST.** On VAST NFS scratch the build became I/O-bound once merges started
  (hot_threads: merge/write threads 62-99% "other"/wait; loaders idle at 2-3% CPU): 944k/s burst -> 130-200k/s.
  Same build with `path.data=/dev/shm/...`: 764k-818k docs/s sustained. A shard of ~30 GB + merge temp fits easily
  in 252 GB shm. Clean /dev/shm at job end (`srun --overlap ... rm -rf /dev/shm/<dir>`). Snapshot to shared VAST.
- If a build is already running and you find a faster config, launch the faster one IN PARALLEL on other nodes and keep
  the old one as a backup until the new one passes its gates — do not restart blindly.

## 2. Index settings during the build
- `number_of_replicas: 0`, `refresh_interval: -1`, `index.translog.durability: async`, `sync_interval 60s`,
  `index.translog.flush_threshold_size: 4gb`.
- Merges get auto-throttled (216-332 s throttled per node observed): `index.merge.scheduler.auto_throttle: false`,
  `index.merge.scheduler.max_thread_count: 6` (dynamic; can be set live).
- After load: `_refresh`, gates, `_forcemerge?max_num_segments=1`, then snapshot (`fs` repo under path.repo).

## 3. Loader (Python, per node, into the node-local ES HTTP port)
- multiprocessing Pool (not threads), `orjson` for parse/serialize, `requests.Session` keep-alive, bulk ~4000 docs.
- Parallelism unit = input FILE: give each node >= as many files as loader procs (90 files / 12 nodes = 7-8 per node).
- Check EVERY bulk item: retry only 429 items; print + count every other item error (never drop silently).
- Write a per-file manifest line {file, rows read, docs expected, docs acked, item errors}. Gates after load:
  all files present, rows read == source total, 0 item errors, acked == expected, ES `_count` == expected.
  Abort (no snapshot) if any gate fails. Compute the expected total independently too (e.g. ES `sum` agg of an
  integer count field: 655,469,985 per-hit docs == sum(protein_pfam_count)).
- `_count` counts top-level docs; `_cat/indices docs.count` includes nested docs — never mix them in gates.

## 3b. ONE WRITER PER FILE (absolute; see global CLAUDE.md)
Per-input-file manifest files + per-node totals files + per-node loader logs (`> $LOGDIR/$SLURMD_NODENAME.log`) +
per-node ES start/stdout files. The gate reads ONLY those. Never a shared manifest, never parse the merged job log, never
rewrite a file writers have open. On a gate failure HOLD the cluster (`wait $ESSTEP`) instead of killing it; use
`srun --kill-on-bad-exit=0` so one node's failure cannot cancel the others.

## 4. Test BEFORE the full run — but test the right things
A 30k-doc 2-node test proved cluster formation / load / gates / snapshot but MISSED the one-core pinning, the VAST
I/O ceiling and the index.sort design error. The test must also: (a) run the real queries (all sorts, collapse) and
check their plans/latency; (b) measure docs/s and per-node CPU (top, `_cat/thread_pool/write`, `_nodes/hot_threads`)
for >= 1-2 minutes at realistic concurrency; (c) record merge throttling. Then launch the full build.

## 5. Moving the snapshot and restoring
- ES 9.2.1 restores ES 8.15 snapshots (N-1 major); build on the same major as the target when possible.
- Transfer Perlmutter <-> dori with the dori key (explicit `-i ~/.ssh/dori -o CertificateFile=~/.ssh/dori-cert.pub`,
  no ControlMaster): 626 MB single scp stream 173 MB/s; 57 GB with 6 parallel rsync streams in ~70 s. Verify with
  md5 (or file list + sizes for snapshot repos) on both sides.
- Pull a snapshot repo with one rsync per shard dir (`indices/*/*/`) + one for the top-level metadata; compare
  `find -printf '%s %p'` listings of source and destination.
- Restore on a read-only mount: register the repo with `{"type":"fs","settings":{"location":...,"readonly":true}}`
  (otherwise write-verify fails on a ro mount). The location must be under the target node's `path.repo`.
  Raise `indices.recovery.max_bytes_per_sec` for the restore.

## 6. Pitfalls seen in the data itself
- `_id` can differ from the logical key after in-place field updates (update_by_query never changes `_id`): 11,593 Pfam
  docs had `_id` Mycocosm:… while fields said Phycocosm (Aug-5 relabel). Gate on the logical key, and explain every
  exception exactly (which rows, why, no collisions) instead of silently allowing it.
