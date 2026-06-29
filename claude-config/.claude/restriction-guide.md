# Restriction / unrestriction workflow guide

Changing a proteome's restriction status touches **four systems** — update all of them.
(There's also a `/unrestrict-proteome` skill that runs this end-to-end.)

## Order of operations

1. **njphytozome.json** (source of truth for the frontend dataPolicy)
2. **CHADO** (makes it durable + drives the API)
3. **njp_content** restriction language (vstId=8)
4. **PMO** — verify only
5. **njp_content_dev** — sync any language change

## 1. njphytozome.json (`~/git/zome-clientside/config/njphytozome.json`)

- Field: `dataPolicy` — a **direct key on each organism node** (NOT under `attributes`). Match the node by its `phytozome_genome_id`.
- `jq --sort-keys` style, 2-space indent. For a minimal diff, do a **targeted line edit** flipping only the `dataPolicy` line nearest above each target `phytozome_genome_id` (don't reserialize the whole file).
- Branches: dev = `trunk`, prod = `production-14.0`. Edit whichever branch(es) the proteome is deployed to. **Dev-only genomes → edit `trunk` only** (they aren't in production-14.0 yet).
- Commit `Unrestrict <comma-separated PIDs>` (no Co-Authored-By). Push the branch(es) edited.
- **CRITICAL — dataPolicy is GENERATED from CHADO.** `update_njphytozome.sh`/`reportClientSideConfig.pl` source `dataPolicy` from CHADO's `data_restriction_policy` at generation time. A hand-edit alone is **reverted by the next `update_njphytozome.sh` regen** unless CHADO is also flipped. So the CHADO step is what makes it durable — never skip it. (Equivalent: flip CHADO first, then regenerate the JSON.)

## 2. CHADO (`data_restriction_policy`)

Per-PID, one at a time:
- Interactive: `module load python; conda activate chado; perl ~/git/compgen/data_wrangling/CHADOio/loaders/loadProteomeProperties.pl -data_restriction unrestricted -annotation_dbxref PACProteome:<PID>`
- **Non-interactive (Claude's Bash tool — `conda activate` does NOT work)**, all in ONE command:
  ```bash
  module unload jamo 2>/dev/null; module load python; conda run -n chado perl ~/git/compgen/data_wrangling/CHADOio/loaders/loadProteomeProperties.pl -data_restriction unrestricted -annotation_dbxref PACProteome:<PID>
  ```
  - `module load python` is REQUIRED first (puts `conda` on PATH). Shell state doesn't persist between Bash calls — load modules in the SAME command. Don't pipe `module load` (subshell loses it).
  - `module unload jamo` first (chado conda env conflicts with the jamo module).
- Success = prints `INFO Committing transaction.` ("There are N old data_restriction records" — N=1 or 2, both fine; it replaces them).
- Use `unrestricted` or `restricted` for the `-data_restriction` value.
- Verify: API `https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<PID>` → `data_restriction_policy` reflects it within seconds.

## 3. njp_content restriction language (vstId=8) — see `~/.claude/njp_content_guide.md`

- DB `njp_content` on plant-db-5. Unrestricted proteomes should NOT carry Ft. Lauderdale / "Reserved Analyses" language; restricted ones SHOULD. Standard unrestricted citation = Pattern C template.
- If a proteome has a real reference DOI (vstId=14), the redundant "Please cite … phytozome-next" boilerplate should be stripped and that vstId=8 row deactivated.
- Always back up before modifying; sync the change to `njp_content_dev`.
- New proteomes often have NO vstId=8 row at all — then there's nothing to clean.

## 4. PMO visibility (verify only — PMs update it, not these scripts)

- Get APID from API xrefs (`dbname=JGIAP`): `…/api/db/properties/proteome/<PID>` → `xrefs[]`.
- Check `https://projects.jgi.doe.gov/pmo_webservices/analysis_project/<APID>` → `uss_analysis_project.visibility`.
- Expect `DataAvailable` (unrestricted) / `Private` (restricted/embargoed). External genomes have no JGIAP xref → nothing to check.
- Note: PMO `visibility` is also what gates the **data portal** file display (separate from `data_restriction_policy`) — see `~/.claude/jamo-guide.md`.

## Verify everything

`/check-restriction-status <PIDs>` cross-references all four systems. Restriction status lives in (and can disagree across): njphytozome.json (both branches), CHADO, PMO/PMO-derived JAMO snapshots, and njp_content language.
