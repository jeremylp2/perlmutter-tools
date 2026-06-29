# Phytozome proteome release checklist

End-to-end steps to release a proteome (dev → prod). Each links to the detailed guide.
"dev-only" = visible on the dev site only; "prod" = on phytozome-next.jgi.doe.gov.

## Data products (must exist before the genome is usable)

1. **CHADO** — genome + annotation loaded into `plant_chado`; chromosome names finalized. (`~/.claude/phytozome-chado-guide.md`; renames: `~/.claude/chado-rename-guide.md`.)
2. **JAMO portal files** — the standard release bundle registered + tagged, with a readme. (`~/.claude/jamo-guide.md`.) Standard set per proteome: `fa.gz` (genome), `softmasked`/`hardmasked.fa.gz`, `repeatmasked_assembly.gff3.gz`, `gene.gff3.gz`, `gene_exon.gff3.gz`, `cds`/`transcript`/`protein`(`_primaryTranscriptOnly`)`.fa.gz`, `P14.analysis.tsv/xml.gz`, `P14.annotation_info.txt.gz`, `P14.defline.txt.gz`, `readme.txt`. Verify with `generateReadmes.py` reference proteomes. **Permissions before registering (664 files / 775 dirs).** Data-portal visibility is gated by `analysis_project.visibility`, not the portal tag.
3. **MongoDB gene documents** — dump from CHADO, load into `phytozome_v14.genes_<pid>`. (`~/.claude/chado-gene-extract-guide.md`.) Verify mongo count == extractor's `Processed N genes.`
4. **JBrowse tarball** — `proteome_progress.jbrowse_tarball_path` (NULL until built); needed for the genome browser tracks.
5. **BLAST databases** — needed for prod sequence search.
6. **BioMart** — genome load into `phytozome_mart_C` + per-organism dataset registration so the org appears in the frontend filter. (`~/.claude/biomart-guide.md`.) Orthologs are a separate load (often deferred).

## Config / content (controls what the site shows)

7. **Deployment** — create a deploy containing the proteome(s); generate + push `njphytozome.json`; switch `current_release`. (`~/.claude/deploy-config-metadata-guide.md`.)
   - Dev: add to dev deploy → push `trunk` → `current_release` env=2.
   - Prod: clone the LIVE prod deploy (verify deployTag first — current_release is often stale!) + add proteomes → push `production-14.0` → `current_release` env=4.
   - njphytozome.json `dataPolicy` is generated from CHADO restriction status.
8. **Restriction status** — set across njphytozome.json (both branches as applicable), CHADO, njp_content, PMO-verify. (`~/.claude/restriction-guide.md`.)
9. **njp_content info-page sections** — overview/notes/contacts/refs (vstId 1/4/6/14/17/18), per proteome. Edit in `njp_content_dev`, then cross-DB copy dev→prod for the released proteomes. (`~/.claude/njp_content_guide.md`.)
10. **Recent Genome Releases** — add `<tr>` rows to `viewProjectSection id=32` (dev and/or prod). Date = release date.
11. **Server deploy** — git push + `current_release` switch do NOT redeploy the running frontend; the `zome-clientside` build/container must be deployed for the new `njphytozome.json` (and new `/info/<jbrowseName>` routes) to go live. Until then `/info/<new genome>` returns "not found" even though the config is correct.

## Gotchas worth re-checking

- **current_release env=4 is frequently stale** — always confirm the live `deployTag` (curl the SPA shell, read the trailing comment) before cloning a prod deploy. Cloning a stale baseline silently drops live proteomes.
- **njphytozome.json is bundled at build time** (webpack `targets: 'njphytozome.json'`) and fetched at runtime as a static asset; a deployTag in the SPA shell can be current while the served config lags until a rebuild.
- **dev content service may read the wrong DB** — confirm `phytozome-dev.jgi.doe.gov/api/content/...` actually reflects `njp_content_dev` (it has been misconfigured to read prod `njp_content`). (`~/.claude/njp_content_guide.md`.)
- **Data-portal file visibility** is gated by `analysis_project.visibility` (DataAvailable vs Private), a denormalized PMO snapshot stale-at-registration — NOT by `portal.identifier`. (`~/.claude/jamo-guide.md`.)

## Verifying a live page

The info page is a React SPA — WebFetch is blocked and the page renders client-side. From Perlmutter, curl the underlying JSON APIs:
`…/api/content/info/<pid>`, `…/api/content/project/<project>`, `…/api/db/properties/proteome/<pid>`, and `…/info/<pid> | tail -10` for the deployTag/commit comment. For full visual rendering, ask the user to load it in a browser.
