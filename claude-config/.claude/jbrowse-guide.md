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
