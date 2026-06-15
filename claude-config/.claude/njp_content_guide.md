# njp_content database guide

## Database location

Host: `plant-db-5.jgi.lbl.gov:3306`
- Production: `njp_content`
- Dev: `njp_content_dev`
- Config section: `[njp_content]` in `~/.confFile`
- Note: the `[njp_content]` section has `dbName=njp_content_dev` (legacy) — always specify the database name explicitly.
- Use `ConfigReader` from `~/git/compgen/deployment_config.py` to read credentials. Use `use_write=True` for writes.

## Key tables

### viewInfoSection — per-proteome info page content
- `id` (PK), `proteomeId`, `vstId`, `sectionContentHtml` (mediumtext), `active` (tinyint)
- Each row is one section of a proteome's info page

### viewInfoSectionType — section type definitions
| vstId | typeName | displayTitle | displayOrder |
|---|---|---|---|
| 1 | overview | Genome Overview | 4 |
| 2 | dataSource | Data Source | 2 |
| 3 | statistics | Genome Information | 5 |
| 4 | notes | Sequencing, Assembly, and Annotation | 6 |
| 5 | availableDataFiles | Related Data Sets | 8 |
| 6 | contacts | Contacts | 9 |
| 7 | associatedPublications | Reference Publication(s) | 10 |
| 8 | restrictions | Restrictions on dataset usage | 7 |
| 9 | imageAttribution | Image credits | 1 |
| 10 | otherPublications | Related Publications | 11 |
| 11 | links and additional info | Additional Resources | 21 |
| 12 | genbank | NCBI GenBank Records | 3 |
| 13 | firstReleaseDate | Phytozome Release Date | 1 |
| 14 | refCiteDOI | Reference Publication(s) | 10 |
| 15 | otherCiteDOI | Related Publications | 11 |
| 16 | dotFiles | Pairwise Orthology Dot Files | 100 |
| 17 | inPress | Submitted / In Press Manuscripts | 12 |
| 18 | relatedGenomes | Related Genomes | 14 |

### viewProjectSection — project-level content (shared across proteomes)
- `id` (PK), `versionId`, `zome`, `vstId`, `sectionContentHtml`, `active`
- Used for project-level content: portal home page sections, shared overviews, inPress items (e.g. SorghumPan, BrapaPan)
- Has its own `viewProjectSectionType` table (same structure as viewInfoSectionType)

#### Recent Genome Releases table
- `id=32`, `versionId='14.0.01'`, `zome='Phytozome'`, `vstId=1`, `active=1`
- This is the table shown on the Phytozome home page listing recently released genomes
- HTML structure:
```html
<div class="new-genome-release">
<h3 style="margin-top: 0;"> Recent Genome Releases</h3>
<div id="adf" style="max-height: 25vh; overflow-x: hidden; overflow-y: auto;">
<table>
<thead><tr><th>Genome</th><th>Common name</th><th>Release Date</th></tr></thead>
<tbody>
<tr><td><a href="/info/JBROWSENAME">Display Name vX.Y</a></td><td>common name</td><td>Mon DD, YYYY</td></tr>
...
</tbody></table></div></div>
```
- Rows are sorted newest-first; insert new rows at the top of `<tbody>`
- `href` uses `jbrowseName` from njphytozome.json (dots replaced with underscores)
- Date format: `"Apr 15, 2026"` — month abbreviation, day (no leading zero), 4-digit year
- Common names: check njphytozome.json `common_name` field first; if empty, check existing entries for same genus; otherwise use standard common name
  - Physcomitrium patens → "spreading earthmoss"
  - Cornus florida → "flowering Dogwood"
  - Lotus japonicus → "birdsfoot trefoil"
  - Boechera spp. → "rockcress"
- To update dev: read prod (id=32) as base, prepend new rows, write to dev. This keeps dev ahead of prod.

#### id=1 row
- `versionId='alpha.13.0.0'`, `active=0` — legacy/inactive, ignore

## Key patterns

### DOI publications (vstId=14)
- `sectionContentHtml` is just the bare DOI string, e.g. `10.1038/s41586-026-10229-9`
- No URL prefix — the frontend resolves via crossref.org
- Multiple DOIs in one section: comma-separated
- If >4 DOIs, frontend falls back to plain links

### Restriction language (vstId=8)
Standard unrestricted citation template (Pattern C):
```html
<dl> <dt> <span style="font-weight: bold;">I would like to use this data to help clone a gene, analyze a gene family, etc.</span> </dt>
<dd>
Please use this data to advance your studies. Please cite "<i>ORGANISM</i> VERSION, DOE-JGI, http://phytozome-next.jgi.doe.gov/info/SHORTNAME_VERSION".</dd>
<dl>
```

### MySQL output parsing
`sectionContentHtml` can contain newlines that break line-by-line parsing. Use:
```sql
SELECT CONCAT('RECSTART', id, '|||', proteomeId, '|||',
  REPLACE(REPLACE(sectionContentHtml, '\n', '{{NL}}'), '\r', ''))
FROM viewInfoSection WHERE ...
```
Then restore: `html.replace('{{NL}}', '\n')`

### Syncing prod → dev
For vstId=14 and 17: overwrite dev rows for proteomes that exist in prod, but keep dev-only rows.
For viewProjectSection id=32 (Recent Genome Releases): read prod as base, prepend new rows, write to dev.

## Live verification (post-edit)

The Phytozome page is a React SPA — `WebFetch` from Anthropic gets blocked by JGI security AND the page renders client-side, so the response body is just an empty shell. From Perlmutter (NERSC IPs), `curl` works against the underlying JSON APIs the SPA fetches from. Use these to verify your edits actually landed without needing a browser.

### viewInfoSection content (per proteome)
```bash
curl -sS https://phytozome-next.jgi.doe.gov/api/content/info/<proteomeId> | jq
```
Returns one JSON object per section: `{proteomeId, typeName, displayTitle, displayOrder, html}`. Inactive rows (active=0) are omitted. The `html` field is the actual rendered HTML with real newlines — exactly what the SPA renders.

### viewProjectSection content (per project)
```bash
curl -sS https://phytozome-next.jgi.doe.gov/api/content/project/<projectName> | jq
# example: phytozome, brapapan, sorghumpan
```
The `phytozome` project's `overview` typeName is the Recent Genome Releases content (id=32).

### Proteome properties
```bash
curl -sS https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<proteomeId> | jq
```
Returns a list (use `[0]`). Includes `data_restriction_policy`, BUSCO scores, scaffold/contig stats, etc.

### Deploy verification
```bash
curl -sS https://phytozome-next.jgi.doe.gov/info/<proteomeId> | tail -10
```
The trailing HTML comment in the SPA shell exposes `deployTag`, `branch`, `commitHash`, `commitDate` — useful for confirming an `njphytozome.json` push to `production-14.0` has been deployed.

## Prod vs dev sites and WHICH njp_content DB each reads

- **Prod site**: `https://phytozome-next.jgi.doe.gov` — reads `njp_content` (prod). Frontend = `production-14.0` branch.
- **Dev site**: `https://phytozome-dev.jgi.doe.gov` — frontend = `trunk` branch. Pages require nginx basic auth, but `/api/content/...` is reachable from Perlmutter. (`njp-spin.jgi.doe.gov` is the internal Spin host from deploy_metadata `ZOME_HOSTNAME` env 2; it does NOT resolve from Perlmutter — use `phytozome-dev.jgi.doe.gov`.)

**CRITICAL — which njp_content DB the DEV content service reads is a per-deployment config, and has been WRONG.** The `zome-content` (content API, port 8592) backing the dev site is *supposed* to read `njp_content_dev`, but on 2026-06-11 it was found misconfigured, reading `njp_content` (prod) instead. Symptom: edits to `njp_content_dev` (e.g. Recent Genome Releases project section id=32, or any viewProjectSection/viewInfoSection) **do not appear on the dev site**.

**Diagnostic** (byte-compare what the dev API actually serves against each DB):
```python
# fetch dev API overview html, compare length/content to njp_content vs njp_content_dev id=32
urlopen("https://phytozome-dev.jgi.doe.gov/api/content/project/phytozome")  # overview typeName = Recent Genome Releases
# if it equals njp_content (prod) id=32 byte-for-byte, the dev content service is reading PROD, not dev.
```
If a dev njp_content_dev edit doesn't show, this is the first thing to check — it's a content-deployment config issue (fixed on the Spin/container side, NOT via SQL). The DB edit itself can still be correct; it just won't render until the dev content service points at `njp_content_dev`.
