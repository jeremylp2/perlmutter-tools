# Plan: Automated Elasticsearch gene re-indexing (per-instance cron)

## Context

ES gene indices must update automatically when gene data changes — especially when a
new proteome is added — instead of being driven by hand. Because IGB VMs and SPIN
cannot mount a common filesystem, the work runs **independently on each of the 4
instances** (dev/prod × SPIN/IGB), each maintaining its own `genes_<pid>.json.gz` dump
directory and its own ES index, on a ~24h supercronic cron.

Most of the machinery already exists in the `zome-elasticsearch` image:
`add_new_accessions.js` (Node orchestrator) queries `proteome_progress`, calls
`mongoexport.sh` (dump) and `index.sh` (ES load), and flips `elastic_search_load`.
The **gap**: `mongoexport.sh` skips a proteome whenever the `.json.gz` already exists
(never refreshes a stale dump), and nothing compares the **live mongo count** to the
dump — so a gene-set change after the original mongo load is invisible (`index.sh` only
compares ES-count vs file-count, so a stale dump looks consistent). We add live-count
verification + redump-on-mismatch, and replace the single-instance field flip with a
**coordination table** so the shared `elastic_search_load` flips to 2 only once **all 4
instances** have indexed the proteome at the current count.

## Decisions (locked with user)

- **Extend the existing Node orchestrator** `add_new_accessions.js`. Node stays; MySQL
  stays in the working `mysql` pool. (No python/bash rewrite.)
- **`index.sh` stays unchanged.** `mongoexport.sh` stays unchanged too — Node deletes a
  stale dump before calling it (mongoexport.sh skips if the file exists, so deleting
  first forces a fresh dump).
- **Uniform eligibility filter, all 4 instances:**
  `gene_mongo_load=2 AND active=1 AND released_in_phytozome>0`
  (replaces the current dev/prod query split; prod may index `released_in_phytozome=1`
  because the frontend hides unreleased entries until release).
- **Single `elastic_search_load` field**, flipped to **2 only when all 4 instances have
  indexed at the current count**, backed by a new coordination table (approved).
- **Mongo count** via the `mongodb` npm driver (not `mongosh`).
- If live mongo count for a proteome is **0 → skip entirely** (no dump/index/coordination).
- Image must be **rebuilt** (transport scripts are baked in via `COPY /scripts/transport`).

## Coordination table

Lives in the **same MySQL DB as `proteome_progress`** (`MYSQLDB_DETAILS.database`).
Instance identity = **explicit `INSTANCE_ID` env** (e.g. `spin-dev`, `spin-prod`,
`igb-dev`, `igb-prod`), set per config. NOTE: `NAMESPACE` is NOT usable as the key — the
SPIN dev and prod clusters BOTH use namespace `plant` (dev/prod differ by **cluster**,
not namespace), so namespace is not unique across the 4 instances. Orchestrator runs
`CREATE TABLE IF NOT EXISTS` at startup each run (no migration tooling).

```sql
CREATE TABLE IF NOT EXISTS es_index_progress (
  proteome_id   INT          NOT NULL,
  instance      VARCHAR(64)  NOT NULL,   -- = INSTANCE_ID
  indexed_count BIGINT       NOT NULL,   -- verified ES doc count after load
  mongo_count   BIGINT       NOT NULL,   -- live countDocuments at index time
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                         ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (proteome_id, instance)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

The all-done check groups by `(proteome_id, mongo_count)` and requires
`COUNT(*) = expectedCount` — this guarantees all instances converged on the **same**
count before flipping (handles mongo drift between instances). `EXPECTED_INSTANCES`
(comma-separated `INSTANCE_ID` values) is injected via env so the denominator is
config-controlled.

## Orchestrator flow (rewritten `add_new_accessions.js`)

1. Parse MySQL secret (JSON, existing) **and** mongo secret (bash `KEY='val'` format —
   regex-parse, **not** `JSON.parse`; URL-encode user/pw into the `mongodb://…?authSource=AUTH_DB` URI).
2. `CREATE TABLE IF NOT EXISTS es_index_progress`.
3. Eligibility (READ): `SELECT proteome_id FROM ?? WHERE gene_mongo_load=2 AND active=1 AND released_in_phytozome>0;`
4. Per pid:
   - `mongo_count = db.collection('genes_'+pid).countDocuments()`; if 0 → skip.
   - `fileCount = exists ? zcat|wc -l : -1`; if `fileCount != mongo_count` → delete stale
     file, `mongoexport.sh <pid>`, re-count, verify `== mongo_count` (else log + skip pid).
   - Read pre-index `esCount` (`_count?q=proteome:<pid>`). If `esCount > fileCount`
     (shrink), index that pid with `index.sh -r -p <pid>` (forces delete+reload — works
     around index.sh only reloading when FILE>ES). Otherwise batch into the normal call.
5. `index.sh -p <pids>` for the normal set (+ the `-r` calls for shrunk pids).
6. Per pid: verify `esCount == mongo_count`; if so upsert `es_index_progress`
   (`INSERT … ON DUPLICATE KEY UPDATE indexed_count, mongo_count`). Do **not** trust
   index.sh exit status (it exits 0 on batch failures) — the ES verify is the gate.
7. All-done flip (idempotent): for candidate pids, run the grouped count check; for pids
   where all expected instances match at the same count,
   `UPDATE ?? SET elastic_search_load=2 WHERE proteome_id IN (?) AND elastic_search_load<2;`
   (never downgrade). Any instance may perform the flip; `<2` makes concurrent flips no-ops.

Use array-bound `?` for `IN (?)` (the `mysql` lib expands arrays); guard empty arrays.
Retire `updateMongoRecords` (its only-missing logic is replaced). Drop the legacy dev
`elastic_search_load=1` write (values become 0 → 2 only).

## File-by-file changes

- **`zome-common-images/elasticsearch/scripts/transport/add_new_accessions.js`** — the
  rewrite above (uniform query, mongo driver count, dump/redump+verify, shrink `-r`,
  ES verify, coordination upsert, all-done flip, table bootstrap, mongo-secret parse).
- **`zome-common-images/elasticsearch/Dockerfile`** — add `mongodb` to the global npm
  install (`npm install -g mysql elasticdump elastic-import mongodb`; NODE_PATH is already
  exported in startup.sh's cron line, so `require('mongodb')` resolves). No other Dockerfile
  change — the stock svc-plant (UID 91278) image is built unchanged on a real Docker daemon
  (see Rollout step 2). Chown-free was considered and rejected.
- **`refactor/zome-elasticsearch/configmap_files/startup.sh`** — cron line: use
  `${CRON_SCHEDULE:-0 1 * * *}`, add `flock -n /tmp/anacc.lock` before `node …`, and
  `mkdir -p /opt/mongoexports/DBDUMP` before the cron block (fresh PVC won't have it).
- **`refactor/zome-elasticsearch/templates/zome-elasticsearch-deployment.yaml`** —
  (a) add a **PVC option for the dump dir** mirroring blast-api
  (`zome-blast-api-deployment.yaml:121-127,178-188`): volume + mount + GET_MONGO_EXPORTS
  gate accept `mongoExportsHostPath` **or** `mongoExportsPersistentClaim`;
  (b) add env `EXPECTED_INSTANCES`, optional `CRON_SCHEDULE`, and **`INSTANCE_ID`**.
- **`refactor/zome-elasticsearch/values.yaml.TEMPLATE`** — add tokens
  `mongoExportsPersistentClaim`, `expectedInstances`, `cronSchedule`, **`instanceId`**.

### Already committed — needs a correction
The orchestrator + chart edits above were already made and committed
(zome-common-images `759eee6` on `trunk`, zome-helm-charts `ec52bf4` on `master`) using
**`NAMESPACE`** as the instance key. Because namespace is not unique (SPIN dev/prod both
`plant`), a follow-up is required before deploy: in `add_new_accessions.js` set
`instance = process.env.INSTANCE_ID` (fallback to NAMESPACE), and add the `INSTANCE_ID`
env (from `.Values.instanceId`) + `instanceId` token to the deployment/values.

## Per-instance config (template_config DB)

Set per config (dev scope = SPIN dev + IGB dev): `getMongoRecords=true`, a unique
`instanceId` (e.g. `spin-dev`, `igb-dev`), identical `expectedInstances` (the dev pair
`spin-dev,igb-dev`), and the same central `__PROCESSING_DB_*__` / `__MONGO_ANNOTATION_DB_*__`
(both MUST share one MySQL + one mongo). Per instance: `platform`, `cluster`, and dump
storage — IGB sets `mongoExportsHostPath`, SPIN sets `mongoExportsPersistentClaim` (leave
the other null; process_template.py renders missing tokens as `null` = falsy). Optionally
stagger `cronSchedule`. (Namespace is `plant` on both SPIN clusters and `igb-dev`/`igb-prod`
on IGB — so `instanceId`, not namespace, distinguishes instances.)

## Verification (no 24h wait)

- Deploy new image+chart to ONE instance (SPIN dev first, per rollout). `kubectl exec`,
  confirm ES **starts as UID 91278** and `/opt/mongoexports/DBDUMP` is writable by the run uid.
- Add a `DEBUG_PID` shim (`if (process.env.DEBUG_PID) pids=[Number(...)]`) for single-pid runs.
  Run `NODE_PATH=$(npm root -g --quiet) TRANSPORT_SCRIPTS=/opt/scripts/transport node …`.
- Check: `zcat genes_<pid>.json.gz|wc -l` == mongo count == `_count?q=proteome:<pid>`;
  one `es_index_progress` row; `elastic_search_load` still NOT 2 (only 1 instance done).
- Redump test (delete a dump line / change a test collection → confirm redump+reindex).
  Shrink test (ES holds more than dump → confirm `-r` deletes+reloads).
  Zero-count test (empty collection → skipped).
- All-4 flip: run on all 4 (or temporarily set EXPECTED_INSTANCES to the live subset) for
  one pid; confirm exactly one flips to 2 and reruns are no-ops.

## Rollout

**SCOPE OF THIS WORK: DEV INSTANCES ONLY.** Roll out to SPIN dev and IGB dev only. Do
**NOT** deploy the new image/chart to either production instance (SPIN prod `plant`, IGB
prod `igb-prod`) in this effort — production rollout is a separate, later decision.

Because production is excluded, set **`EXPECTED_INSTANCES` to the two dev namespaces only**
during this work (so the all-done denominator = 2 and the dev pair can be exercised
end-to-end). When prod is eventually added, `EXPECTED_INSTANCES` gets expanded to the full
4 at that time. Note: with dev-only in the expected set, `elastic_search_load` *can* flip
to 2 once both dev instances index a proteome — confirm that's acceptable for dev, or set
`EXPECTED_INSTANCES` to the full 4 now so nothing flips until prod joins later. (Decide at
implementation time; default to the dev pair so the flip path is actually tested.)

1. Pre-reqs: confirm both dev configs share one MySQL+mongo; write-user has CREATE/INSERT/
   UPDATE; audit consumers of `elastic_search_load` for any `=1` dependency.
2. **Build via hand-off to a real Docker daemon (laptop).** Rootless podman on Perlmutter
   cannot build the UID-91278 image (91278 > 65535, the top of the delegated subuid map, so
   an in-build `chown 91278` returns EINVAL), and we are NOT making the Dockerfile chown-free.
   So the stock image is built with Docker (root daemon, no subuid limit) from the
   `es-auto-reindex` branch via `build_push_to_registry -i zome-elasticsearch -r jgi -u
   svc-plant`, producing `library.jgi.doe.gov:5050/dsi/phytozome/zome-common-images/
   zome-elasticsearch:<git-hash>-svc-plant`. A detailed hand-off doc is provided
   (`~/zome-es-reindex-build-handoff.md`). Once the image is pushed, deploy + verify proceed
   from Perlmutter (this session has kubectl/helm + the dev kubeconfigs).
3. **Deploy to SPIN dev FIRST** and run the full verification section there: single-pid
   (`DEBUG_PID`) run, redump/shrink/zero-count tests, coordination-row check. SPIN dev also
   exercises the new dump **PVC** path (the more complex storage), so validating it first
   surfaces any PVC/fsGroup issues. Fix anything before proceeding.
4. Then IGB dev (validates the hostPath dump path).
5. Confirm both dev instances complete a cycle: coordination rows present, counts match,
   and the flip behaves per the `EXPECTED_INSTANCES` choice above.
6. **STOP — do not touch production.** Hand off prod rollout as a separate task.

## Confirmed with user

- `active` is strictly 0/1. ✓
- MySQL write-user has `CREATE TABLE`. ✓
- SPIN dump PVC is writable by gid 91292 (fsGroup). ✓
- All instances read the same central mongo + `proteome_progress`. ✓
- Instance topology: dev/prod differ by **cluster**, not namespace. SPIN dev = the
  `development.yaml` cluster, namespace `plant` (reachable; I have no SPIN-prod kubeconfig,
  so prod can't be touched). IGB dev = `zome-igb-2` cluster, namespace `igb-dev`. Identity
  is the per-config `instanceId` (e.g. `spin-dev`, `igb-dev`), since namespace isn't unique.
- Runtime UID stays 91278 (svc-plant); not lowerable. The image is built on a real Docker
  daemon (laptop hand-off) — rootless podman can't chown to 91278 and we're keeping the
  Dockerfile chown-ful (see Rollout step 2).

Still to confirm: `on_hold` is intentionally dropped from eligibility, and no consumer
depends on `elastic_search_load=1` (legacy dev value being retired).
