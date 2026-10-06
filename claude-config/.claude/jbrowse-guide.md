# JBrowse (Phytozome) guide

Durable operational knowledge for building, verifying, repairing and deploying Phytozome JBrowse 1
browsers. Project-specific state lives in the mkjb project memory; this file is the stable how-to.

## Where things live

| Thing | Path |
|---|---|
| Public browsers (PROD) | `/global/dna/projectdirs/plant/phytozome/jbrowse/<shortname>` |
| Private browsers | `/global/dna/projectdirs/plant/phytozome/jbprivate/<shortname>` |
| Dataset index | `<PROD>/fulldataset.json` |
| Build workspace | `/pscratch/sd/p/phillips/mkjb` |
| Public build script | `mkjb/build_jbrowse.sh` |
| JAWS WDL pipelines | `~/git/compgen/compute_farm/jbrowse/{JBP,JBPublic}` |

- **Browsers live at `$PROD/<shortname>` — NOT under a `genomes/` subdirectory.** `fulldataset.json`
  urls read `?data=genomes/<shortname>`; `genomes/` is a **webserver alias**. Checking
  `$PROD/genomes/<shortname>` will make you wrongly conclude a browser isn't deployed.
- `/global/dna` is **read-only from login nodes**. All writes go through `ssh`/`scp dtn01.nersc.gov`,
  authenticated by the on-disk key `~/.ssh/nersc` (no agent/cert needed; survives logout).

## Anatomy of a browser directory
```
<shortname>/
  seq/refSeqs.json        reference sequences (ORDER MATTERS)
  tracks/<label>/<refseq>/trackData.json[z]  + names.txt + lf-*.json[z] (lazy chunks)
  names/                  global name index (search box) — built by generate-names.pl
  trackList.json          ALL track display config
  custom/expression/*.bw  bigwig coverage files
```

### Two rules that explain most confusion
1. **`generate_tracklist.py` rewrites the WHOLE `trackList.json` at the end of a build.** Therefore
   the `flatfile-to-json --config` glyph/category you pass at build time is **discarded** — only the
   track *data* matters. One generic `flatfile-to-json --trackType CanvasFeatures --compress` build
   works for every CanvasFeatures track; the display config comes from `generate_tracklist.py`.
2. **`refSeqs.json[0]` drives `defaultLocation`.** If organelles sort first the browser opens on a
   sparse chloroplast/mito. Reorder so `chloro|mito|plastid|plastome|mitogenome` sort LAST.

## GFF format traps (these cause silent, invisible data loss)
- **`flatfile-to-json --gff` is a GFF3-only parser** (splits col9 on `;` then `=`). GFF2 column 9
  (`Target "Motif:X" s e;class "Y"`, quoted **or unquoted**) is silently dropped — you get a track
  with no `class`/`Target`/`Name`. RepeatMasker/IGC output is GFF2 → must normalize col9 first.
- **PASA** GFF2 is `match` + following `HSP` lines grouped by `Target` **in file order**, with no
  ID/Parent. Convert with a running counter (`ID=pasa%08d`, HSPs get `Parent=`) — **never key on
  Target**, the same target legitimately recurs at other loci.
- **Chado export styles `jbrowse-primary` / `jbrowse-alt` set `gene_feature=0`** — no gene line is
  emitted, so anything attached only to the gene (e.g. a gene `symbol` featureprop) is dropped
  unless the exporter merges it onto the mRNA.
- Some "extra" GFFs have orphan `Parent=` on mRNA rows (no gene line) → strip it or the parse errors.

## Searchability vs display
- A feature attribute shows in the popup/label if it's in the track data.
- It is **searchable** only if it was indexed: `flatfile-to-json --nameAttributes "name,alias,id,<attr>"`
  at **build** time. `generate-names.pl` has **no** attribute flag — it only aggregates what the
  track build already emitted. To make e.g. gene symbols searchable you must rebuild the track.

## Verifying / comparing browsers
- **Compare with `names.txt`, not a hand-rolled NCList walker.**
  `cat tracks/<label>/*/names.txt | sort` then `comm -3` between two browsers is deterministic.
  A naive recursive NCList traversal gives **false differences** because lazy-chunk (`lf-*.jsonz`)
  structure differs between builds of identical data.
- Feature *attributes* aren't in names.txt — to compare those, diff the **source GFFs** that were
  fed to flatfile-to-json.
- Integrity gate worth running before deploying anything (`verify_browser.py` in the JBPublic work):
  every trackList entry has a track dir; track seqids intersect `refSeqs`; required tracks non-empty;
  RepeatMasker has `class`; PASA has HSP subfeatures; `defaultLocation` is a real refSeq;
  `names/meta.json` exists.

## Surgical single-track replacement (the safe pattern)
Used repeatedly (RepeatMasker class fix, PASA backfill, LORE1 swap, gene symbols). Never rebuild a
whole browser to fix one track:
1. Rebuild ONLY that track's data in scratch from its exact recorded source.
2. Verify the new track (feature counts, expected attributes, seqids ⊆ deployed `refSeqs`).
3. `tar` the currently-deployed track dir to a scratch backup.
4. `scp` the new dir to `dtn01:.../tracks/<label>.new`, `chgrp -R wwwzome`, `chmod -R a+r`,
   dirs `a+x`, then **atomic swap**: `mv <label> <label>.old_tmp && mv <label>.new <label> && rm -rf <label>.old_tmp`.
5. Confirm with `ls --time-style=long-iso` that **only** the intended paths changed.
Adding a *new* track additionally requires inserting its `trackList.json` entry — load the JSON,
append, and assert every pre-existing entry is byte-identical.

## Deploy checklist (public)
`chgrp -R wwwzome` · `chmod -R a+r` · `find <dir> -type d -exec chmod a+x {} \;` ·
`update_fulldataset.py <pid>` (handles its own dna read/write over dtn01) ·
`mark_jbrowse_deployed.py <pid>`.
Note `annotation_version` from the API already has a leading `v` — don't add another.

## JAWS/WDL notes (JBPublic / JBPrivate)
- **`jaws submit` forbids parent-directory imports** (`import "../JBP/task/..."`) — imports must be
  in a subdirectory of the main WDL. Vendor shared tasks instead. (`jaws validate` does NOT catch this.)
- Validate with the inputs: `jaws validate <wdl> <input.json>` catches binding errors.
- Docker images must be **public** (Shifter cannot pull private) and pinned by **full sha256** —
  see `podman-perlmutter-guide.md`, including the Docker-Content-Digest trap.
- JAWS compute nodes cannot reach the JGI databases, so DB work (tracking query, Chado export)
  must happen on a login node; **everything else — decompression, conversion, building — belongs in
  the WDL**, not in a pre-script.

## Misc
- Login-node `python3` is **3.6**: `subprocess.run(text=…, capture_output=…)` fails (3.7+ only).
  Use `universal_newlines=True` + `stdout=PIPE`. This has silently broken helper scripts before.
- Chado GFF export needs `module load python` **then** `conda activate chado`.
- Browser pages can't be fetched by Claude (`WebFetch` of phytozome 403s from Anthropic IPs) —
  ask the user to eyeball the browser, and tell them to hard-reload (track data is cached).

## Liftoff ("Mapped Models from X") tracks — refactored pipeline (2026-08)
Code: `/pscratch/sd/p/phillips/liftoff/` (scratch, not yet in git; old copies in
`~/git/compgen/analysis/liftoff` use the obsolete tarball input).
- WDL `liftoff_and_track.wdl` → `liftoff.wdl` + `makeLiftoffTrack.wdl`. Input `File target_tracklist`
  (the target browser's live trackList.json) — NO browser tarball. `updateTrackList` image pinned
  `python@sha256:7b72fe8ab313d9b48755f1350fa2a42c723a80e6bf7beb5e03b801e5405ecb15`.
- `configLiftoffWDL.py <pid1> <pid2> --trackInput <abs path> --cpu N` (login node): picks the LAST
  non-PURGED JAMO genome + gene_exon annotation, `jamo fetch`+cp into the pair dir, copies each target's
  trackList.json from /global/dna into the pair dir, writes both `*_vs_*.json` configs. `--trackInput`
  must be ABSOLUTE (script chdirs into the pair dir).
- Submit: `prepare_multiple_jaws.py --input_pairs pairs.tsv --workdir W --script_root <liftoff dir>
  --cluster dori --cpu 4 --output_file runs.txt` (one line per unordered pair; submits both directions).
  4 cpu is plenty (lift ≈ 4 min at 32 cpu); big cpu requests sit in queue for hours.
- Deploy: `deploy_liftoff_dna.py runs.txt [--dry-run] --stamp $(date +%Y%m%d_%H%M%S)` — reads
  `jaws status` output_dir/outputs.json, live-merges only the new `Mapped*` entry into the CURRENT dna
  trackList (safe for many tracks → same browser), scp via dtn01, wwwzome/a+r, verifies by direct read.
  Run in screen; python stdout is buffered (use `python3 -u`), so judge progress by dna track counts.
- Liftoff data dir naming: label `Mapped_Models_from_<queryShort>`, key `Mapped Models from <queryShort>`.

## JAWS site notes (observed 2026-08)
`jaws list-sites` shows only static caps. Judge real scheduling with `jaws tasks <id>` (QUEUE_START→RUN_START)
and `jaws log <id>`; top-line `done` can be a staging failure. jgi = Lawrencium (fast queue; occasional
transient image-pull flake → consider `maxRetries`). defiant = OLCF (Globus endpoint was down). crux
submissions were disabled by the JAWS team.

## Building a browser whose source data is only on dori
Tracking may point at `/clusterfs/...` (dori), unreadable from Perlmutter. scp the genome / RM / gaps /
bigwig from dori (see dori-guide.md; key `~/.ssh/dori`, MaxSessions 1 → sequential) into a scratch
staging dir with the SAME filenames, then run build_jbrowse.sh with `OVERRIDE_SRC_DIR=<staging>`
(override block redirects GENOME/REPEATS/GAPS/BIGWIG dirs; was in `build_jbrowse_dori.sh` copy as of
2026-09 — check whether folded into build_jbrowse.sh).

## build_jbrowse.sh operational notes
- `MINIPROT_TIME` env overrides miniprot sbatch walltime (default 0:20:00). miniprot runs ~1–3 min on
  ~1 Gb genomes; oversized walltime on `--exclusive` jobs badly hurts backfill. A pending job's walltime
  can be cut in place: `scontrol update jobid=<id> TimeLimit=00:20:00` (keeps job id → batch waits intact).
- Never edit build_jbrowse.sh while any build using it is running (bash reads scripts incrementally).
- get_extra_gff_meta.py emits 7 TAB fields (path,file,label,glyph,category,transcriptType,subParts);
  build_jbrowse.sh must take them by index.
- deploy_one.sh → mark_jbrowse_deployed.py needs `pymysql`. NERSC user-site is per python BUILD
  (`~/.local/perlmutter/python-3.13/<build>/`); when the default `python` module build changes, pymysql
  vanishes → deploy_one exits 1 AFTER scp+verify → batch skips update_fulldataset. Fix:
  `module load python && pip install --user pymysql`, then run update_fulldataset.py / mark manually.

## RNA-coverage bigwig audit
For every trackList track with BigWig storeClass or `.bw` urlTemplate: file must exist, start with
bigWig magic `26fc8f88`, be world-readable, parent dir o+rx. Missing files: source path is in Chado
tracking (`filetype='bigwig'`, subtype RNAseqExpression) — copy via dtn01 into `custom/expression/` with
the trackList's filename. (2026-08: 3 missing + 1 unreadable found and fixed.)
