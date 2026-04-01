---
description: Add a DOI reference publication to proteome(s) in njp_content, deactivate any inPress sections, and sync to dev
---

Given arguments: $ARGUMENTS

Expected format: `<DOI> <PID1>,<PID2>,...` e.g. `10.1038/s41586-026-10229-9 730,781,734`

## 1. Validate

- Check that each proteome ID exists via `https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<PID>` (returns a list, use `[0]`)
- Check if a refCiteDOI (vstId=14) already exists for each proteome in njp_content

## 2. Insert refCiteDOI

Database: `njp_content` on `plant-db-5.jgi.lbl.gov:3306`
- Read with web user (credentials in `~/.confFile`)
- Write with phillips user (credentials in `~/.confFile`)

```sql
INSERT INTO viewInfoSection (proteomeId, vstId, sectionContentHtml, active)
VALUES (<PID>, 14, '<DOI>', 1)
```

The sectionContentHtml is JUST the DOI string (e.g. `10.1038/s41586-026-10229-9`), not a URL.

## 3. Deactivate inPress (vstId=17) if present

Check both tables:
- `viewInfoSection` where `vstId=17 AND active=1 AND proteomeId=<PID>` — set `active=0`
- `viewProjectSection` where `active=1` and `vstId` matches `inPress` type — check if the content relates to the same paper/proteomes

## 4. Sync to njp_content_dev

For each proteome that was updated in prod:
- Delete any existing vstId=14 row for that proteome in njp_content_dev
- Insert the new row from prod
- Similarly sync vstId=17 deactivations

## Notes

- The DOI format in the database is just the DOI path (no `https://doi.org/` prefix)
- The frontend (`processInfo.js`) resolves DOIs via crossref.org at render time
- If more than 4 DOIs are in a single section (comma-separated), the frontend falls back to plain links instead of resolved citations
- vstId reference: 14=refCiteDOI, 15=otherCiteDOI, 17=inPress
