---
description: Full workflow to unrestrict proteome(s) — updates njphytozome.json (both branches), CHADO, njp_content restriction language, and verifies PMO visibility
---

Given proteome ID(s): $ARGUMENTS

This is a multi-system workflow. For each proteome ID (comma-separated):

## 1. Update njphytozome.json (BOTH branches)

In `~/git/zome-clientside/config/njphytozome.json`:
- Set `dataPolicy` from `restricted` to `unrestricted` for matching `phytozome_genome_id`
- Do this on **both** `production-14.0` and `trunk` branches
- Commit with message: `Unrestrict <comma-separated PIDs>`
- No co-authored-by line
- Push both branches

The JSON is a nested clade tree — walk `childClades` and `organisms` recursively. Match on `attributes.phytozome_genome_id`.

## 2. Update CHADO restriction status

```bash
module unload jamo 2>/dev/null
conda run -n chado perl ~/git/compgen/data_wrangling/CHADOio/loaders/loadProteomeProperties.pl \
  -data_restriction unrestricted -annotation_dbxref PACProteome:<PID>
```

Verify it prints `INFO Committing transaction.`

## 3. Clean restriction language in njp_content

Check `viewInfoSection` where `vstId=8 AND active=1 AND proteomeId=<PID>` for Ft. Lauderdale / Reserved Analyses language.

Keywords to check for: `ft. lauderdale`, `fort lauderdale`, `reserved analyses`, `reserved analysis`

If present, replace with the standard citation template (Pattern C):
```html
<dl> <dt> <span style="font-weight: bold;">I would like to use this data to help clone a gene, analyze a gene family, etc.</span> </dt>
<dd>
Please use this data to advance your studies. Please cite "<i>ORGANISM_NAME</i> VERSION, DOE-JGI, http://phytozome-next.jgi.doe.gov/info/SHORTNAME_VERSION".</dd>
<dl>
```

Get organism name, version, and shortName from njphytozome.json.

Database: `njp_content` on `plant-db-5.jgi.lbl.gov:3306`
- Read with web user (credentials in `~/.confFile` under `[njp_content]`)
- Write with phillips user (credentials in `~/.confFile` under `[njp_content]`)

Always save a backup JSON before modifying (old_html, new_html, db_id).

## 4. Verify PMO visibility

Get JGIAP xref from `https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<PID>` (returns list, use `[0]`; check `xrefs` array for `dbname=JGIAP`).

If xref exists, check `https://projects.jgi.doe.gov/pmo_webservices/analysis_project/<APID>` — response is under `uss_analysis_project`. Verify `visibility` is `DataAvailable`.

If no JGIAP xref, report that (external genome — no PMO to check).

## 5. Sync njp_content_dev

If restriction language was changed in njp_content, sync the same proteome's vstId=8 row to njp_content_dev.
