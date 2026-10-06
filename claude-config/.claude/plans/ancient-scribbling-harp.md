# Plan: Fix RepeatMasker repeat-class display (existing tracks + both pipelines)

## Context

RepeatMasker tracks in newer JBrowse builds don't show the repeat **class** (and often
Target/Name) in the feature popup. Root cause, proven empirically:

- `flatfile-to-json.pl --gff` parses column 9 as **GFF3** (`key=value`). The classic
  RepeatMasker / IGC output is **GFF2** (`Target "Motif:X" s e;class "Y"`, sometimes
  **unquoted**: `Target Motif:X s e;class Y`). The GFF3 parser splits on `;` then `=`,
  finds no `=`, and **silently drops** those attributes — leaving only bare columns
  (Start/End/Strand/Type/Score/Source/Seq_id).
- Browsers whose source is genuine GFF3 (e.g. EDTA `classification=…`) are unaffected.
- Older browsers (pre-`--gff`) were built by a GFF2-aware tool and are fine.

Both the public pipeline (`build_jbrowse.sh`) and the JBPrivate WDL (`buildBoxTrack`) use
`--gff`, so both produce broken tracks for GFF2 sources.

**Hard constraint (user):** touch **only** RepeatMasker track data. Do not modify
`trackList.json`, `seq/refSeqs.json`, the `names/` index, or any other track — for any
browser, public or private. Detection-gated: only rebuild tracks that are actually broken.

## Scope (audited 2026-06-14, read-only)

- **Public:** 37 broken / 426 OK / 100 no-RM-track. Broken = recent `build_jbrowse.sh`
  builds from GFF2 sources (Gossypium, AUTEX250, Abelmoschus, Boechera, Cornus, Lotus
  Gifu, etc.). Exclude junk: `Egold`, `zzy`.
- **Private:** 73 broken / 34 OK / 4 non-browser. **63 real** after excluding junk
  (`*_devel`, `*_test*`, `*testing`, `*.bak_*`, `*HAP1test*`, `CCC52_*test*`,
  `CSH10test`, `zzy`).
- Lists captured in `/pscratch/sd/p/phillips/mkjb/_rmtest/` (`broken_private_real.txt`,
  public audit output).

## Source-of-truth for rebuilds (seqid-verified — never trust a name match alone)

- **Public:** Chado tracking `subtype='similarity:RepeatMasker'` by `proteome_id`
  (map deployed shortname→proteome_id via PAC2_0/API). 658 RM GFFs total.
- **Private:** `/global/cfs/cdirs/plantbox/annotation/<genus>/…/*repeatMask*gff*`
  (genus dirs hold many GFFs; pick by seqid match). JBPrivate runs executed on **dori**
  (`workflowRoot: …/dori-prod/…`); the perlmutter `szaman/<id>/<uuid>/input.json`
  (`JBPrivate.validateRepeatGFF.gff_file`) records sources for the ~6 with a perlmutter
  copy, but the annotation dir is the site-independent source.
- **Resolution rule:** for each broken browser, collect candidate source GFFs, normalize,
  and accept the one whose **seqid set == deployed `seq/refSeqs.json` seqids**. If none
  match on cfs, check dori filesystems; if still unresolved (`Tspecies`, `Ufusca`,
  `Wmirabilis`, `Csativa` are likely candidates), **report and skip** — never rebuild from
  an unverified source.

## Component 1 — the normalizer (`/pscratch/sd/p/phillips/mkjb/normalize_repeat_gff.pl`)

Finalize the validated prototype in `_rmtest/`. Per-attribute, syntax-generic; safe no-op
on clean GFF3 (verified byte-identical on EDTA/962). Handles every col9 signature found in
the 658-file wider-net survey:

- `key=value` (GFF3) → passthrough; strip wrapping quotes from value (`class="X"`→`class=X`).
- `key "value" [s e]` (quoted GFF2) → `key=value`; for `Target`, emit `Target=value s e`
  **and** derive `Name=` (strip `Motif:`).
- **`key value [s e]` (UNQUOTED GFF2)** → same as above. *(New branch — required by ~10
  public files: chlamy, Saccharum R570, Q.rubra, O.sativa IRGSP, B.mexicanum, A.comosus,
  cassava, wheat Thatcher, sorghum, O.sativa Kitaake, P.vaginatum.)*
- Unknown tokens kept verbatim (never silently lose data).

Re-validate against one representative file from **every** survey signature bucket
(`_rmtest/chado_rm_col9.tsv`) end-to-end (normalize → flatfile-to-json → decode attrs).
Note: sources with no class at all (1053/1054 Target-only; `Match/length`) can only
recover Target/Name/Match — there is no class to show; that is expected, not a failure.

## Component 2 — fix public pipeline (`/pscratch/sd/p/phillips/mkjb/build_jbrowse.sh`)

Step 7 (RepeatMasker, ~lines 294–306): before the `flatfile-to-json.pl --gff` call, run
`normalize_repeat_gff.pl "$REPEATS_LOCAL" > "$REPEATS_LOCAL.norm"` (system perl on the
login node) and feed `.norm` to flatfile-to-json. Only the RepeatMasker step changes;
Gaps/extra_gff/miniprot untouched.

## Component 3 — fix JBPrivate pipeline (`~/git/compgen/compute_farm/jbrowse/JBP/task/trackBuild.wdl`)

In task `buildBoxTrack` (used only for repeats), inline the normalizer in perl (the
`jbrowse/jbrowse-1.12.0` image has perl) and run flatfile-to-json on the normalized file.
Leave `buildGFF3Track` and all other tasks untouched. **Commit + push branch `jlp_dev`**
to origin. Production branch szaman's runs build from is unconfirmed → **hand off to
szaman** to route the merge (note this in the commit message).

## Component 4 — backfill existing broken tracks

New script `/pscratch/sd/p/phillips/mkjb/repair_repeatmasker.sh` (run in `screen` on a
recorded login node; deploy to dna via `dtn01.nersc.gov`). Per browser:

1. **Detect** (reuse audit logic): decode `tracks/RepeatMasker/<refseq0>/trackData.json(z)`
   classes; broken iff attrs ∩ {class,classification,target,name,alias} = ∅. Skip if OK.
2. **Resolve source** (seqid-verified, above). Unresolved → log + skip.
3. **Rebuild** in `$SCRATCH`: `normalize_repeat_gff.pl` → `shifter … flatfile-to-json.pl
   --gff norm.gff --out <scratch> --trackLabel RepeatMasker --config '{glyph Box,
   category Alignments}' --compress --trackType CanvasFeatures`.
4. **Verify** new track: attrs now include class/Target/Name (or Target/Name where no
   class exists); seqid set == deployed refSeqs.
5. **Swap (only `tracks/RepeatMasker/`):** tar the deployed dir to
   `$SCRATCH/rm_backups/<shortname>/` (reversible), copy new dir to a temp sibling on dna,
   atomic `mv` into place, then `chgrp wwwzome` / `chmod a+r` / dirs `a+x`. Nothing else
   in the browser is read or written.
6. **Pilot first:** `Mprimuloidesvar_PRIL1_v1_1` (private) + `Ghirsutumvar_TM1_v3_2`
   (public). Verify in browser before the full batch.

## Verification

- Re-run the public+private audits; broken count should fall to only the
  report-and-skipped (unverifiable-source) browsers.
- Browser spot-checks (user, since WebFetch is blocked): primuloides, a Gossypium, a
  Bdistachyon variety, 1053 — popup shows class/Target where the source has them.
- Pipelines: build one new public browser end-to-end from a GFF2 source and confirm the RM
  popup shows class; same for one JBPrivate run after szaman picks up the WDL change.

## Out of scope / explicit non-actions

- No change to `trackList.json` (the `feature.get('class')` label function stays; EDTA-style
  `classification` already shows in the popup, which the user confirmed is correct).
- No change to OK browsers, junk/dev/test/bak dirs, or any non-RepeatMasker track.
- Unresolved-source browsers are reported, not modified.
