# JAMO Guide (Phytozome file metadata & tape archive)

JAMO is JGI's file metadata + tape-archive system. Every Phytozome release file is a
JAMO record: metadata in MongoDB-backed Lapin API, bytes on disk/tape under
`/global/dna/dm_archive/plant/phytozome/<Gspecies>/<version>/{assembly,annotation,analysis}/`.

**ALWAYS `module load jamo` first** — it puts `sdm_curl` on PYTHONPATH and the `jamo` CLI on PATH.
Cannot coexist with the conda `chado` env (`module unload jamo` before conda chado work).
**Never pipe `module load jamo` or run it in a subshell** (`module load jamo | …`, `(module load jamo; …)`) — the PATH/PYTHONPATH change is lost in the subshell and `python3` then fails `No module named 'sdm_curl'`. Chain with `;`/`&&` in the same command instead (`module load jamo && python3 …`); plain redirections are fine.

## Auth — token file + appToken vs token

Token file `~/.jamo/token`, one server per line (URL contains `://`, so split on whitespace, NOT `:`):
```python
import os, re
from sdm_curl import Curl
token = None
for line in open(os.path.expanduser('~/.jamo/token')):
    s = line.rstrip().split()
    if len(s) == 2 and re.sub(r':$', '', s[0]) == 'https://jamo.jgi.doe.gov':
        token = s[1]; break
curl = Curl('https://jamo.jgi.doe.gov', appToken=token)
```
- `Curl(server, appToken=token)` → header `Authorization: Application <token>` → can **write** (PUT/POST).
- `Curl(server, token=token)` → reads only; writes return 403 "not authorized to access ... put_filemetadata".
- Same token value; only the header scheme differs.

## Querying

```python
# many files (proteome_id is indexed and fast; file_path $regex is NOT — it times out)
r = curl.post('api/metadata/pagequery', data={
    'query':  {'metadata.phytozome.phytozome_genome_id': 988},   # or proteome_id; or {'$regex':...} on file_name
    'fields': ['_id', 'file_name', 'file_path', 'file_status', 'metadata.portal.identifier'],
    'cltool': True,
})
recs = r.get('records', r) if isinstance(r, dict) else r

# one file, full doc
curl.get(f'api/metadata/file/{file_id}')
```
- pagequery returns at most ~1000 records and **ignores page/pageSize params** — for >1000 files, query by narrower keys, don't paginate.
- CLI: `jamo report select _id, file_name where metadata.phytozome.proteome_id in '(988)'` (escape parens; quote the where-clause). CLI `report` index lags fresh registrations (shows `file_name: None` for a few minutes).

## Writing metadata — merge semantics (CRITICAL)

```python
curl.put('api/metadata/filemetadata', data={
    'id':       file_id,
    'metadata': {'portal': new_portal},   # only top-level keys you send are touched
})
```
- Merges at the **top-level key** level: sending `{'portal': {...}}` affects only `metadata.portal`; `phytozome`, `analysis_project`, etc. untouched.
- **Within a key the entire value is REPLACED.** To change one sub-field of `metadata.phytozome` (or `analysis_project`, `portal`, …) you must read the whole block, mutate, send it all back. Sending a partial block wipes the rest.
- Every PUT (even a no-op identical value) bumps `metadata_modified_date`/`modified_date` → can trigger downstream re-index; can briefly drop a file from views.
- **Verify every PUT**: re-fetch and assert the field, e.g. `assert curl.get(f'api/metadata/file/{id}')['metadata']['portal']==new_portal`.

## Registering a NEW file (api/metadata/file)

```python
curl.post('api/metadata/file',
    file='/path/in/portalStaging/.../file.fa.gz',   # local source
    file_type='fasta',                               # fasta|gff|text|tsv|misc_file|...
    put_mode='Replace_If_Newer',                     # reuses existing record at same destination
    destination='phytozome/<Gspecies>/<ver>/<subdir>/<filename>',  # archive path under dm_archive/plant/
    metadata={...})                                  # full metadata dict (see classification + portal below)
```
- **PERMISSIONS FIRST, ALWAYS (unskippable):** `chmod 664` the file and `chmod 775` every parent dir up to portalStaging, verified with `stat`, *before* the POST. JAMO ingests asynchronously; if the file/dir isn't readable at ingest the record can land with no `file_name`. See `feedback_jamo_permissions.md`.
- JAMO **re-stamps `analysis_project` from live PMO at registration time** — so a freshly-registered file captures the *current* AP visibility, while old files keep their stale snapshot (see Visibility below).
- A new record ingests through `REGISTERED-INGEST` → `BACKUP_READY`/`BACKUP_COMPLETE` (file_name populates once ingested).
- Easiest correct metadata for a new file: copy the full `metadata` dict from a sibling already-registered file of the same proteome, then override `type/subtype/content/format`, `portal`, and the filename-specific bits.

## metadata.portal — what the Phytozome browser/JDP index on

```python
'portal': {
  'identifier': ['Phytozome', 'PhytozomeV14', '<Gspecies>'],          # + FD key to also appear in JDP FD project
  'display_location': {
    'Phytozome':    ['PhytozomeV14', '<data_portalname>', '<ver>', '<category>'],
    'PhytozomeV14': ['<data_portalname>', '<ver>', '<category>'],
    '<Gspecies>':   ['<ver>', '<category>'],
    # optional FD: '<FD_key>': ['<FD_bucket capitalized: Assembly|Annotation|Analysis>'],
  },
}
```
- `category` (lowercase): `assembly` (`.fa.gz`, soft/hardmasked), `annotation` (cds/transcript/protein, gff3, repeatmasked_assembly, P14.annotation_info, P14.defline), `analysis` (P14.analysis.tsv/xml).
- Identifier lists are **unioned** across portals — a file shows in every portal whose key it lists.
- `Gspecies` (no underscores) from API `organism_gspecies`; `data_portalname` (underscores, strip apostrophes) from API `data_portalname`; `ver` = `annotation_version`.
- API: `https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<id>` → list, use `[0]`.
- To HIDE from portal: `metadata.portal = {}`.
- Canonical filename→category rules: `~/git/compgen/JAMO/merge_1043_portals.py` (FILE_RULES). Registration code: `~/git/compgen/data_wrangling/CHADOio/loaders/jamoProteomeFiles.py`.

## Visibility — what the DATA PORTAL actually gates on

The data portal reports a file as existing based on the **denormalized `metadata.analysis_project` snapshot**, NOT `portal.identifier`:
- **shows** if `analysis_project.visibility == 'DataAvailable'` (or no `analysis_project` block at all), and `availability_date` is past/null-appropriate.
- **hidden** if `visibility == 'Private'` (typically with a future `availability_date`, `embargo_days` > 0).

This snapshot is captured at registration and **does not auto-update** when PMO changes. So files registered at different times can disagree: e.g. proteome 988 had 5 recently-registered files = `DataAvailable` (current PMO) while 12 older FD-ingested files = stale `Private` — only the 5 showed. To harmonize, copy a sibling's `metadata.analysis_project` block onto the others via PUT (same AP id, so the block is otherwise identical). `portal.identifier` being equal across files does NOT make them all show — check `analysis_project.visibility` first.

(Separately, JDP "My Data Portal" private search HIDES files carrying Phytozome `portal.identifier` tags — opposite direction; see `jamo_jdp_visibility.md` / GitLab issue #107.)

## Classification — metadata.type/subtype/content/format/source

Five top-level fields per Phytozome file (GenTech/raw-delivery files lack them). Canonical values per filename suffix and the `.analysis.tsv.gz` bulk-fix story: `jamo_classification_taxonomy.md`. Quick refs:
- `.fa.gz` genome → assembly/sequence/unmasked/fasta; soft/hardmasked → assembly/sequence/`masked,repeats`/fasta
- `.gene.gff3.gz`,`.gene_exon.gff3.gz` → annotation/gene/structural/genes/gff3
- `.repeatmasked_assembly.gff3.gz` → annotation/repeat/structural/`DNA,repeats`/gff3
- `.P14.analysis.{tsv,xml}.gz` → analysis/functional/`InterProScan,E2P2,Pathologic`/{tsv,xml}

## phytozome stanza & release

`metadata.phytozome`: `Gspecies`, `proteome_id`/`phytozome_genome_id`, `proteome_name`, `version`, `annotation_version`, `assembly_version`, `data_release_policy` (restricted|unrestricted), `phytozome_release_id` (e.g. `['14','current']`). To **deprecate** an old/duplicate file: set `portal={}` AND `phytozome.phytozome_release_id=['13']` (drops it from current release) — see `jamo_file_replacement_guide.md`.

## Restore from tape (PURGED files)

`file_status: PURGED` = bytes on tape only. Restore submits to `api/tape/grouprestore`; status goes PURGED → RESTORE_REGISTERED → RESTORE_IN_PROGRESS → RESTORED/on-disk over minutes-to-hours.
```bash
module load jamo
python ~/git/compgen/JAMO/restoreProteome.py 995 996 1002          # restore all on-tape files for proteome id(s)
python ~/git/compgen/JAMO/restoreProteome.py 995 --dry-run         # show status, submit nothing
python ~/git/compgen/JAMO/restoreProteome.py 995 --token-file PATH
```
(`pjamo.py` is a lower-level general query/fetch tool also using grouprestore; `fetchPhytozomeBundle.py` only grabs a subset for bundling.)

## Useful scripts (~/git/compgen/JAMO/)

`restoreProteome.py` (tape restore by proteome) · `merge_1043_portals.py` (FILE_RULES + union portal template) · `generateReadmes.py` (render+register readmes with portal stanza) · `jamoProteomeFiles.py` (in CHADOio/loaders — canonical registration that builds portal/phytozome metadata) · `fetchPhytozomeBundle.py` · `pjamo.py`.

## Endpoints / file_status / gotchas

- Endpoints: `GET api/metadata/file/<id>` · `POST api/metadata/pagequery` · `PUT api/metadata/filemetadata` · `POST api/metadata/file` (register) · `POST api/tape/grouprestore`. (`/raw|/audit|/history` fall through to the main doc — no JAMO history available.)
- `file_status`: `BACKUP_COMPLETE`/`BACKUP_READY`/`RESTORED` = on disk; `PURGED` = on tape; `REGISTERED-INGEST` = ingesting.
- `file_owner`/`file_group` = registrant identity captured at registration, NOT live disk owner; not visibility-gating.
- `file_path` (archive storage dir) is independent of `portal.display_location` category — a genome mis-filed under `/annotation` still displays as assembly if the portal stanza says so; re-file only for tidiness.
- Per-proteome ad-hoc JAMO scripts are one-offs — don't need git commits (see `feedback_no_commit_one_offs.md`).
