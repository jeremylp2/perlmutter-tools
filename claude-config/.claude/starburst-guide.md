# Starburst / Trino Access & Database Guide (JGI Lakehouse)

Everything needed to connect to the JGI Starburst (Trino) coordinator and query the federated
source databases + the lakehouse. Compiled from the cross-domain PFAM work (Phytozome + Mycocosm +
Phycocosm + IMG). Companion state docs: `/global/cfs/cdirs/plant/xdomain_pfam/{STATE,SESSION_STATE_2026-07-07,HYBRID_AND_V2_STATE,APP_DEPLOY_STATE}.md`.

---

## 1. The two lakehouse engines (don't confuse them)

| Engine | Host | Auth file | Notes |
|---|---|---|---|
| **Starburst / Trino** (PRIMARY) | `lakehouse-pov.jgi.lbl.gov:443` | `~/.starburst_jwt` | The one this guide is about. SQL over federated catalogs. |
| Dremio (older POC) | `lakehouse-poc.jgi.lbl.gov` | `~/.dremio_pat` | UI at that host; SSO only. Separate system; mostly superseded by Starburst. |

`pov` = Starburst (**p**roof **o**f **v**alue), `poc` = Dremio. Easy to fat-finger.

---

## 2. Authentication (the important, non-obvious part)

The token in `~/.starburst_jwt` is an **encrypted JWE backed by a server-side STATEFUL SSO session**.

- **Renewing is NOT "get a new token string."** Visiting `https://lakehouse-pov.jgi.lbl.gov/ui/token`
  in a browser sends your SSO cookie, which **refreshes the server-side session**, so the *same token
  bytes* start validating again. The file usually doesn't need to change.
- **Touching / re-saving `~/.starburst_jwt` does nothing** server-side. The renewal is the page visit.
- **`401 / Invalid credentials`** → the SSO session lapsed → **visit `/ui/token`** (page load only, no
  copy-paste needed), then retry. If the file bytes genuinely changed, re-save them.
- `502` / `PAGE_TRANSPORT` errors are transient coordinator hiccups, not auth — just retry.
- The token must **never** appear on a command line (it's a credential). Read it from the file.

---

## 3. Connecting

### A. Raw `trino-python-client` (what the ad-hoc analysis scripts use — simplest)

```python
import trino, trino.auth
from pathlib import Path
JWT = Path('~/.starburst_jwt').expanduser().read_text().strip()
cur = trino.dbapi.connect(
    host='lakehouse-pov.jgi.lbl.gov', port=443, http_scheme='https',
    auth=trino.auth.JWTAuthentication(JWT),
).cursor()
cur.execute('SHOW CATALOGS')
print(cur.fetchall())
```

`trino` is pip-installable; a working copy is vendored at
`/pscratch/sd/p/phillips/pfam_es_build/pydeps313` (Python 3.13). On Perlmutter: `module load python`.

### B. The repo wrapper (`StarburstClient`) — used by the benchmarks

```python
import sys; sys.path.insert(0, 'phytozome-import-starburst')
from starburst_utils import make_client, show_catalogs, time_query
client = make_client()                 # reads ~/.starburst_jwt, host defaults to lakehouse-pov
print(show_catalogs(client))
secs, df = time_query(client, "SELECT 1")
```
- `make_client(encoding="none", client_timeout="180m", catalog=..., schema=...)`. `encoding="none"`
  disables the spooling protocol (the server has it off) — keep it.
- Wraps `starburst-api-python/src/starburst_api_python/StarburstClient`; `.query()` returns a
  DataFrame, `.execute()` runs DDL/DML. Discovery helpers: `show_catalogs`, `find_pg_catalog(hint)`,
  `find_iceberg_catalog`.
- Run any benchmark with `--discover` first to print catalog names (they carry version suffixes that
  change — never hardcode blindly; `SHOW CATALOGS` is the source of truth).

### C. CLI
`trino --server https://lakehouse-pov.jgi.lbl.gov:443 --access-token "$(cat ~/.starburst_jwt)"`
(if the `trino` CLI jar is installed).

---

## 4. Catalogs (federated sources + lakehouse)

Catalog names are **quoted** (hyphens) and carry a backend suffix. Always `SHOW CATALOGS` to confirm —
the numeric suffix (e.g. `-7`, `-2`) can rotate. Known catalogs used in the PFAM work:

### Source relational DBs (live JDBC federation — read-only in practice)
| Catalog | Backend | What it is | Key schema(s) |
|---|---|---|---|
| `"img-db-2_postgresql"` | Postgres | **IMG** (isolate + metagenome genomes) | `img_core_v400` |
| `"plant-db-7_postgresql"` | Postgres | **Phytozome CHADO** (plants) | `public`, `deploy` |
| `"portal-db-1_mysql"` | MySQL | **Mycocosm/Phycocosm frontend config** (the JGI fungal/algal portal) | `portal` |
| `"myco-db-{1,2,3}_mysql"` | MySQL | **Mycocosm per-genome DBs** (one schema per genome) | `<genome_schema>` |

There is also a **MongoDB** catalog family (`"plant-db-4"`-style) exposing homolog collections
(`diamond_homologs_v14`) — used by the homolog work; confirm the exact name with `SHOW CATALOGS`.

### Lakehouse (writable)
| Catalog | Type | Use |
|---|---|---|
| `staging_iceberg` | Iceberg | **Writable** analytics tables. Schema `xdomain` holds `pfam_annotation`, `protein_sequence`. Partition with `WITH (partitioning = ARRAY['pfam_id'])` / bucketing. |
| `staging_hive` | Hive | Stage partitioned Parquet, then `CALL staging_iceberg.system.migrate(...)` — far faster than many tiny `INSERT`s. |
| S3 bucket `lakehouse-staging` | object store | Physical Parquet behind the Iceberg tables. Endpoint `sgrid-03.jgi.lbl.gov:10443` (path-style, TLS). Readable directly with DuckDB `httpfs` (see §7). |

**Single-writer rule:** one writer per Iceberg table, ever. Loops append sequentially or stage to
Parquet then one `migrate`. Never concurrent writes.

---

## 5. Key tables (the ones proven in the PFAM pipeline)

### IMG — `"img-db-2_postgresql".img_core_v400`
- **`taxon`** — one row per genome. Columns: `taxon_oid` (genome id), `ncbi_taxon_id`,
  `taxon_display_name` (organism), `is_public` ('Yes'/'No'), `obsolete_flag`, `is_replaced`,
  `seq_status`, `domain` (Bacteria/Archaea/Viruses/Eukaryota, plus `Plasmid:*`/`GFragment:*` prefixes),
  `phylum`, `genome_type` ('isolate' | 'metagenome'). Isolates = 199,015.
- **`gene`** — `gene_oid`, `locus_tag` (the stable id, e.g. `Ga0112756_116938`), `product_name` (defline), `taxon`.
- **`gene_pfam_families`** — the PFAM hits (isolate-only; metagenome PFAM lives in `numg`). `pfam_family`
  is `pfam#####` → uppercase to `PF#####`.
- **`pfam_family`** — `pfam_family` → `name` (pfam_name).
- Clean-genome filter used: `genome_type='isolate' AND is_public='Yes' AND obsolete_flag='No' AND
  ncbi_taxon_id IS NOT NULL` + NCBI-kingdom ∈ {bacteria,archaea,virus,protist}.

### Phytozome — `"plant-db-7_postgresql"`
- `public.organism`, `public.organism_dbxref`, `public.dbxref`, `public.db` — organism→NCBI taxid via
  `db.name='Taxonomy'` (`dbxref.accession` = taxid).
- `deploy.proteome_progress` — released proteomes: `WHERE released_in_phytozome=2` (454).
- PFAM annotations come from the CHADO feature/analysis tables; PFAM key is the `accession` (`PF#####`).
- **plant_chado access rule:** only `public`, `denormalized`, `json_export` schemas — never others.
  `search_path` defaults to `chado`, so **always schema-qualify** (`public.organism`).

### Mycocosm / Phycocosm frontend — `"portal-db-1_mysql".portal`
- **`organismConfigProd`** (`C`) — sections/genomes: `name`, `parent`, `deleted`. Walk the `parent`
  chain to classify: a genome is **Phycocosm** if any ancestor ∈
  `{fungal-program-phycocosm-genome, fungal-program-phycocosm-groups}` (mirrors
  `PortalConfig.isFungalProgramPhycocosmGenome`).
- **`organismConfigPropertyProd`** (`P`) — per-genome properties (long format): `organism`, `name`,
  `value`, `deleted`. Useful `name`s: `taxonomyId`, `kingdom`, `phylum`, `displayName`, `genus`,
  `species`. Get taxids:
  `SELECT lower(organism), value FROM P WHERE deleted=0 AND name='taxonomyId' AND value<>''`.
- This catalog federates the WHOLE JGI portal config (all programs), not just our loaded set — filter
  to your genome list.

### Mycocosm genome DBs — `"myco-db-{1,2,3}_mysql".<schema>`
- One MySQL schema per genome. **`proteinipr`** (`domaindb='HMMPfam'`): `domainid`→pfam_id,
  `domaindesc`→pfam_name, `proteinid`→protein_id. Defline cascade: `protein.description` →
  `proteinipr.iprdesc` → `kog`. A genome is "loaded" if it has a `proteinipr` table.

---

## 6. Query gotchas
- **Quote catalog names** with hyphens: `"img-db-2_postgresql".img_core_v400.taxon`.
- Fully-qualified names are `"catalog".schema.table`.
- Catalog suffixes rotate — resolve via `SHOW CATALOGS` / `find_pg_catalog(hint)`, don't hardcode.
- Federated JDBC pushdown is decent but big cross-source joins are slow; pull each side, join locally,
  or stage to Iceberg.
- Interactive queries have a ~1–2s floor; Starburst is for analytics/ETL, not point-serving. For
  point lookups the source DB (or MongoDB/Postgres) wins.
- `encoding="none"` (spooling disabled) — if you see spooling-protocol errors, this is why.

---

## 7. Reading the lakehouse Parquet directly with DuckDB (no Trino)
The physical Parquet in `s3://lakehouse-staging/...` (endpoint `sgrid-03.jgi.lbl.gov:10443`) is
readable straight from DuckDB — fast, and it works from Perlmutter **login AND compute nodes**
(compute-node egress to sgrid was verified). Credentials live in the k8s secret `pfam-build-s3`
(keys `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`) — pull them into a chmod-600 env
file, never hardcode.

```python
import duckdb, os
c = duckdb.connect(); c.execute("INSTALL httpfs; LOAD httpfs;")
c.execute(f"SET s3_endpoint='{os.environ['S3_ENDPOINT']}'; SET s3_url_style='path'; SET s3_use_ssl=true;")
c.execute("SET s3_url_compatibility_mode=true;")
c.execute(f"SET s3_access_key_id='{os.environ['S3_ACCESS_KEY_ID']}'; SET s3_secret_access_key='{os.environ['S3_SECRET_ACCESS_KEY']}';")
c.execute("SELECT count(*) FROM read_parquet('s3://lakehouse-staging/*/xdomain.db/pfam_annotation_v2-*/data/**/*.parquet')").fetchone()
```
The `*` after the bucket is the Trino catalog/schema prefix; DuckDB globbing handles it.

---

## 8. NCBI taxonomy classifier (for kingdom work)
Built this session, reusable: `/pscratch/sd/p/phillips/ncbi_tax/taxid_group2.pkl` =
`(group_dict, merged_dict)` — `group_dict` maps 2.85M taxids → one of
{plant, fungus, alga, protist, animal, bacteria, archaea, virus, other, unclassified, unknown};
`merged_dict` remaps old→new taxids (99,720). Built from NCBI `new_taxdump` (`fullnamelineage.dmp`,
`merged.dmp`, `categories.dmp`) in the same dir. Classify: `group_dict.get(merged_dict.get(t,t),'NOT_FOUND')`.
Eukaryote sub-classification is by phylum keywords (Chlorophyta/Rhodophyta/Bacillariophyta/… → alga,
Streptophyta+Embryophyta → plant, Fungi → fungus, else → protist).

---

## 9. Writable-load pattern (Iceberg) — quick reference
1. Extract per source → partitioned Parquet on CFS (hive layout) or into `staging_hive`.
2. `CALL staging_iceberg.system.migrate(...)` OR `INSERT ... SELECT` into
   `staging_iceberg.xdomain.<table>` (`WITH (partitioning=ARRAY['pfam_id'])`).
3. One writer only. Verify counts across sinks.
See `phytozome-import-starburst/load_homologs_inplace.py` and `scripts/load_pfam_annotation.py` for
real examples.
