---
description: Cross-reference restriction status across njphytozome.json, CHADO, PMO, and njp_content for proteome(s) or all proteomes
---

Given proteome ID(s): $ARGUMENTS

If argument is "all", check all proteomes in njphytozome.json. Otherwise, check the comma-separated proteome IDs provided.

## Systems to check

For each proteome, gather restriction status from all four systems and report mismatches:

### 1. njphytozome.json (source of truth)

Read `~/git/zome-clientside/config/njphytozome.json`. Walk the nested clade tree (`childClades` → `organisms`). The field is `attributes.dataPolicy` (`restricted` or `unrestricted`). Check on the **current branch** (typically `production-14.0`).

### 2. CHADO (via Phytozome API)

`https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<PID>` — returns a list, use `[0]`. Field is `data_restriction_policy`.

### 3. PMO visibility

From the same API response, get JGIAP xref from `xrefs` array (`dbname=JGIAP`, `accession` has the APID).

If APID exists: `https://projects.jgi.doe.gov/pmo_webservices/analysis_project/<APID>` — response under `uss_analysis_project`, field is `visibility`. Expected: `DataAvailable` for unrestricted, `Private` for restricted/embargoed.

If no JGIAP xref: report as "external genome — no PMO".

### 4. njp_content restriction language (vstId=8)

Database: `njp_content` on `plant-db-5.jgi.lbl.gov:3306` (read with web user from `~/.confFile`).

Check `viewInfoSection WHERE vstId=8 AND active=1 AND proteomeId=<PID>`.

Look for Ft. Lauderdale keywords: `ft. lauderdale`, `fort lauderdale`, `reserved analyses`, `reserved analysis`.

An unrestricted proteome should NOT have this language. A restricted proteome SHOULD.

### Handling newlines in MySQL output

When reading `sectionContentHtml`, newlines in the HTML break line-by-line parsing. Use `REPLACE(sectionContentHtml, '\n', '{{NL}}')` with a unique delimiter in the query, then restore after parsing.

## Output

Print a table: `PID | Organism | njphytozome.json | CHADO | PMO | vstId=8 language | Issues`

Only print rows with mismatches unless argument is a specific list of PIDs (then print all).
