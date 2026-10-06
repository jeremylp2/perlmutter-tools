# Group-data service — pangenomes + haplotype-resolved genomes

## Context
Need a JSON endpoint listing Phytozome groups (pangenomes and haplotype-resolved genome sets) with, per member genome, the
JAMO records of its key files and an overall availability from PMO — for internal (JGI, AP-id-bearing) genomes. It must be
its own service (own app, own swagger doc) living in the zome-webservices repo. Rollout: local test → dev (SPIN) → prod (IGB).

## Decisions (user, 2026-10-02)
- CHADO is the source of truth. NEVER PAC2_0 (intermediate, internal-only).
- Hierarchical JSON: group → members → components → files.
- Group: id keyed by type (`phytozome_pangenome_id` | `phytozome_hap_resolved_genome_id`), group name, member count,
  availability; pangenome: reference proteome id(s) if any.
- Member: proteome id, genome name as shown elsewhere (/properties/proteome + info pages), e.g. "Andropogon gerardi HAP1 v1.1",
  AP id.
- Components (JAMO files with phytozome_release_id containing 'current'):
  - genome_fasta: unmasked genome .fa.gz only (by classification assembly/sequence/unmasked/fasta, not filename — 783's genome
    file is named `_v1.0.fa.gz` under annotation v1.1)
  - annotation_gff: `gene_exons.gff3.gz` always
  - transcripts_fasta: full + primaryTranscriptOnly
  - proteome_fasta: full + primaryTranscriptOnly
  - per file: JAMO id, file name, current location = JAMO `file_path` + `file_status`, final deliverable id, AP id.
- Availability from PMO (`DataAvailable` | `Private`); group is DataAvailable only if ALL components are.
- External (AP-less) groups DO exist (verified 2026-10-02: 19 groups — brachypan 56/57 members no AP, cowpeapan 8/8, 17 hap sets
  fully AP-less; JAMO files also have no AP/FD for sampled members). REVISED (user): default = internal only (every member has
  an AP); `include_external=true` adds AP-less groups; a type+id request returns the group even if external. External groups
  are returned with AP null and flagged (`internal: false`).
- Query modes: all (default) · one type · one type + id.

## Verified facts (2026-10-02)
- CHADO plant_chado (plant-db-7): grp type 39366 = pangenome (6 grps, 161 members), 39334 = organism_haplotype (81 grps,
  162 members). Reference: grpmemberprop type 39367 value '1' (every pangenome has ≥1; eucypan has 2 = 993+994).
  Members: feature_grpmember → peptide_collection feature (type 1608) → PACProteome xref (db 172) = proteome id.
  Example: grp 1516389043 "Andropogon gerardi v1.1" (2 members: 783, 784).
- JGIAP per proteome: dbxref_relationship (subject = PACProteome dbxref, object = JGIAP dbxref) — same SQL as
  `processing/controllers/chado-controllers.js` detailsProteomePMO.
- JAMO `api/metadata/pagequery` on `metadata.phytozome.phytozome_genome_id` returns per file `_id, file_name, file_path,
  file_status, metadata.final_deliv_project_id, metadata.analysis_project_id, type/content/format,
  phytozome.phytozome_release_id` (783: FD 1183554, AP 1337859, 20 files). Read token: `Curl(server, token=…)` scheme.
- PMO public: `https://projects.jgi.doe.gov/pmo_webservices/analysis_project/<AP>` → `uss_analysis_project.visibility`.
- prod `/api/db/properties/proteome/783`: organism_name "Andropogon gerardi HAP1", annotation_version "v1.1".

## Implementation
Branch off freshly fetched `origin/master` in `~/git/zome-webservices` (e.g. `groups-service`). Nothing committed/pushed
without explicit go.

New top-level dir `groups/` modeled on `processing/` (copy structure, not shared code):
- `groups.js` — express + swagger-tools app, basePath `/api/groups`, swagger UI at `/api/groups/docs`, health check.
- `api/swagger.yaml` — own doc:
  - `GET /api/groups` (all) · `GET /api/groups/{type}` · `GET /api/groups/{type}/{id}`; `type` enum
    `pangenome | hap_resolved`; 400 bad type/id, 404 unknown id, 422 external group (no AP) with message.
- `controllers/groups-controllers.js`:
  1. CHADO: one query for groups + members (+ ref flag) filtered by type/id; one for member names (same SQL that
     dbservices `/properties/proteome` uses for organism_name + annotation_version — read it before coding) and JGIAP.
  2. JAMO: per member pagequery (bounded concurrency), keep 'current' files, select the 4 components per the rules above;
     missing/extra files → warnings.
  3. PMO: per distinct AP id (from JAMO file metadata + CHADO JGIAP), fetch visibility; component availability =
     visibility of its AP; group availability = DataAvailable iff all components DataAvailable, else Private.
  4. Assemble hierarchical JSON `{groups:[…], warnings:[…]}`; log warnings.
  - Short TTL in-memory cache for JAMO/PMO results (value proposed at implementation; listing all ≈ 320 JAMO queries).
- `config.json.TEMPLATE` (chado connection, JAMO URL, token file path) — real config via env var, never in repo.
- `package.json`, `Dockerfile`, `helm/` (Chart.yaml, values.yaml, templates) following `processing/`; README section.

## Verification
- Local on Perlmutter (screen, logged), real CHADO/JAMO/PMO:
  - `/api/groups/hap_resolved/1516389043` → 2 members 783/784; 783 files match the JAMO listing above
    (genome `AgerardiHAP1_783_v1.0.fa.gz`, gene_exons gff, 2 transcript, 2 protein files; FD 1183554; AP 1337859).
  - brapapan → reference [795]; eucypan → references [993, 994]; 50 members.
  - `/api/groups` totals: 81 hap groups / 162 members, 6 pangenomes / 161 members; list every warning.
  - bad type → 400; unknown id → 404.
  - swagger docs page loads.
- Then dev deploy (SPIN) on user go; then prod (IGB) on user go.
