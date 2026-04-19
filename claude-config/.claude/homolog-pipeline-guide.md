# Homolog Pipeline Guide

End-to-end reference for the diamond/inparanoid homolog pipeline for Phytozome.
This pipeline computes pairwise protein homologs between proteomes and loads the
results into MongoDB for serving via the Phytozome web service.

## Data flow

```
PostgreSQL (plant_chado)
  │
  │  pac_gene_view_callt(pid, 1)        [get_deflines.py]
  ▼
Defline TSV files (~/inparanoid/defline/output_files/output_{pid}.tsv.gz)
  │
  │  FASTAs via getFastaFromPAC.pl      [prepare_jaws.py]
  ▼
FASTA files (~/inparanoid/{pid}.fa)
  │
  │  JAWS workflow: diamond_homologs.wdl
  │  - run_inparanoid (scatter over all pairs)
  │  - run_diamond   (scatter over all pairs)
  │  - compute_multiplicity
  │  - generate_json (to_json.py inside the homolog-pipeline Docker image)
  ▼
JSON tarball on CFS (call-generate_json/execution/json_{pid}.tar.gz)
  │
  │  collect_results.py extracts + loads
  ▼
MongoDB `diamond_homologs_v14` (host plant-db-4.jgi.lbl.gov)
  Collections named `homologs_{pid1}_{pid2}` (pid1 = home/query, pid2 = partner/hit)
```

## Key file locations

| Path | Contents |
|------|----------|
| `~/git/compgen/data_wrangling/MONGOio/pipeline/` | Pipeline source (git) |
| `/pscratch/sd/p/phillips/inparanoid/` | Working dir (has local copies of scripts during dev) |
| `/pscratch/sd/p/phillips/inparanoid/defline/output_files/` | Defline TSV.gz files |
| `/pscratch/sd/p/phillips/inparanoid/homologs/output_json/` | mongoloader JSON files (after extract) |
| `/global/cfs/cdirs/plantbox/homology/inparanoid_homologs/all_db/{pid}/` | Persistent inparanoid table files |
| `/global/cfs/cdirs/plantbox/phytzm-jaws/phillips/{jaws_run_id}/{cromwell_id}/` | JAWS output dirs (per submission) |

## Proteome status fields (MySQL `deploy_config_metadata.proteome_progress`)

Each proteome tracks three progress bits:

| Field | Meaning |
|-------|---------|
| `homolog_blast_compute` | Pairwise diamond hits computed |
| `inparanoid_computes` | Inparanoid orthology tables computed |
| `homolog_load_mongo` | Homolog JSON loaded into MongoDB |

Each uses the same `Status` IntEnum (from `config.py`): `PENDING=0, RUNNING=1, DONE=2, ERROR=-1`.

## Prepare + submit (manual)

```bash
source ~/jaws-prod.sh
module load python/3.11-24.1.0
cd /pscratch/sd/p/phillips/inparanoid

python3 pipeline/wdl/prepare_jaws.py \
    --new-prots 947,1044,1045 \
    --site dori \
    --monitor \
    --poll-interval 300
```

`prepare_jaws.py` steps:
1. Resolve partners — all proteomes with `released_in_phytozome >= 1 OR to_compute > 0`, minus skip list
2. Extract missing FASTAs (getFastaFromPAC.pl)
3. Fetch missing deflines (get_deflines.py) — **does NOT regen existing files unless `--force`**
4. Bundle all deflines into `deflines_all.tar.gz`
5. Submit one JAWS run per new proteome (can be parallel on site)
6. With `--monitor`: poll every `--poll-interval` seconds; on completion, call `collect_results.py` for that proteome

The whole run holds a **pipeline_lock** (see `pipeline-lock-guide.md`) so only one instance can run across all hosts.

## Automated pipeline (cron)

- scrontab entry: `0 */6 * * * /global/u1/p/phillips/git/compgen/data_wrangling/MONGOio/pipeline/wdl/run_homolog_cron.sh`
- Uses `homolog_cron.py` to find proteomes that need compute and call `prepare_jaws.py` flow
- Also holds `pipeline_lock` → will skip cycle if a manual run is active

## JAWS run lookup

Runs are tagged `homologs_{pid}`. Look up by tag:

```bash
jaws history --tag homologs_947 --days 90
```

Returns a JSON array with `id`, `status`, `result`, `output_dir`, etc. No local state files are used.

## Collecting results manually

If `--monitor` is not used or crashed, run the collect step by hand:

```bash
source ~/jaws-prod.sh && module load python/3.11-24.1.0
python3 pipeline/wdl/collect_results.py --proteome 947
```

Sequence:
1. Look up run via `jaws history --tag homologs_947`
2. Validate the JSON tarball (spot-check)
3. Copy inparanoid table files to CFS persistent storage
4. Insert table paths into MySQL `diamondparanoid_loc`
5. Extract JSON tarball into `output_json/`
6. Load into MongoDB (`run_load_mongo([pid])` — default drop+create each collection)

## MongoDB load modes (`load_mongo.py`)

| Mode | Flag | Behavior |
|------|------|----------|
| Default | (none) | For each JSON file: drop collection, create with zlib compression, mongoimport, create indexes |
| Skip-if-loaded | `--no-drop` | If collection has data, skip. Else load without drop+create. Use only when collections are known to already exist empty with zlib. |

`load_mongo.py` tracks failures per-file and raises a RuntimeError at the end listing any files that failed. `mongoimport` uses a YAML credentials file (`password` only) with other connection options on the command line, keeping credentials out of `ps`.

## Collection naming convention

`homologs_{P1}_{P2}` where **P1 is the query proteome** and **P2 is the hit proteome**.
- Records have `queryIdentifier` = a P1 protein's PAC id
- Records have `hitIdentifier` = a P2 protein's PAC id
- `hitDefline` = the defline string for `hitIdentifier` (from P2's defline file)
- `toProt` = `str(P1)`, `hitProteome` = `str(P2)` (file-level constants)

Both directions exist: `homologs_A_B` and `homologs_B_A` — one per JAWS run that included the pair.

## Common troubleshooting

**"API returns 0 docs for proteome X"**: check `homologs_X_*` collection exists and `queryIdentifier` in a sample doc actually belongs to X. If not, the data has the query/hit swap bug (historical bug, fixed in commit f65e2670 — see lessons.md Bug 17).

**"hitDefline is empty for many records"**: the partner's defline file is stale or incomplete. Run `/homolog-audit` to find stale proteomes. Regenerate with `python3 pipeline/get_deflines.py --prots X --force`.

**"Cron stuck held"**: scrontab job in SLURM may be in held state (`squeue -u $USER -p cron` shows `(user env retrieval failed requeued held)`).
- **DO NOT** try `scontrol release <jobid>` — fails with `Cannot modify scrontab jobs through scontrol`.
- **DO NOT** try `scancel <jobid>` alone — fails with `Cannot cancel scrontab jobs without --cron flag`.
- `scancel --cron <jobid>` works but DISABLES the scrontab entry (`#DISABLED:` prefix) — you'd have to `scrontab -e` to uncomment it afterward.
- **Recommended fix**: reinstall the scrontab, which creates fresh jobs in normal PENDING state:
  ```bash
  scrontab -l > /pscratch/sd/p/phillips/scrontab_new.txt
  # (if any lines start with #DISABLED:, remove that prefix)
  scrontab /pscratch/sd/p/phillips/scrontab_new.txt
  # All cron jobs get new IDs in reason=BeginTime (not held)
  ```
- After reinstall, first scheduled run tests whether env retrieval works now. If it still fails (re-enters held), the cause is deterministic — file a ticket with NERSC to check slurmctld logs.

## Env setup for wrappers / subprocesses

The pipeline uses two separate environments for different tools:
- **chado conda env** (`conda activate chado` after `module load python`) — perl with DBD::mysql, python with pymongo/mysql.connector/psycopg2. Used for: FASTA extraction (`getFastaFromPAC.pl`), PG queries, mongo loads.
- **jaws-prod venv** (`source ~/jaws-prod.sh`) — the `jaws` command (submit, status, history, etc.)

**These two envs CANNOT coexist in one shell**:
- Sourcing jaws-prod AFTER activating chado overrides perl (→ system perl, no DBD::mysql) and python (→ jaws-prod python, no pymongo).
- Chado env contains a STALE `jaws` binary at `/global/cfs/cdirs/jgisftwr/plant/zome/conda/envs/chado/bin/jaws` — **DO NOT** rely on it.

**Canonical wrapper for homolog pipeline** (runs `homolog_cron.py` / `prepare_jaws.py` / `collect_results.py`, all of which call `jaws` via subprocess):
```bash
#!/bin/bash
source ~/jaws-prod.sh          # makes `jaws` command available; sets jaws-prod env vars
module load python/3.11-24.1.0  # restores user's python (with mysql.connector, pymongo via ~/.local)
cd /path/to/workdir
python3 <script>
```

**Perl calls via subprocess from python** (for `getFastaFromPAC.pl` etc.) must wrap their own subshell to activate chado:
```python
# See prepare_jaws.py::ensure_fasta (commit a2d4da58)
import shlex
perl_cmd = (
    "module load python/3.11-24.1.0 && "
    "conda activate chado && "
    f"perl {shlex.quote(extractor)} ..."
)
subprocess.run(["bash", "-lc", perl_cmd])
```
The `bash -lc` ensures `.bashrc` conda init is sourced so `conda activate` works.

**"pipeline_lock held"**: another instance (manual run or cron) is already running. Check with `SELECT GET_LOCK('homolog_pipeline', 0)` in deploy_config_metadata — returns 0 if held. Check who holds it via `performance_schema.metadata_locks` or just wait for it to complete.
