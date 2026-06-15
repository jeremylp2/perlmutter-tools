---
name: repair-repeatmasker-class
description: Fix a deployed Phytozome JBrowse browser whose RepeatMasker track is not showing the repeat class/Target/Name in the feature popup. Rebuilds ONLY tracks/RepeatMasker from the browser's EXACT recorded source GFF (never sequence or fuzzy-name matching) and atomically swaps it on dna. Use when a public or private browser's repeats render as bare boxes with no class.
---

# Repair RepeatMasker repeat-class on a deployed browser

## When to use
A deployed browser's RepeatMasker feature popup shows no **class** / **Target** / **Name**
(repeats are bare boxes). Root cause: it was built with `flatfile-to-json --gff` (GFF3 parser)
on a GFF2-style RepeatMasker source, which silently drops those attributes. Full background:
the `repeatmasker-class-fix` and `session-state-2026-06-14-repeatmasker` project memories.

## Absolute rule — EXACT mappings only
NEVER pick a source GFF by sequence/seqid overlap or fuzzy name matching (many genomes are
near-identical). The source MUST come from a definitive record:
- **PUBLIC** (`/global/dna/projectdirs/plant/phytozome/jbrowse/<sn>`): shortname → proteome_id
  via `fulldataset.json` (top key `"datasets"`, `jbrowseName`→`id`) → the one Chado RM GFF for
  that proteome (`plant_chado` on plant-db-7, `tracking_*`, `subtype='similarity:RepeatMasker'`).
- **PRIVATE** (`/global/dna/projectdirs/plant/phytozome/jbprivate/<sn>`): the JBPrivate
  `input.json` record (`JBPrivate.validateRepeatGFF.gff_file` / `repeat_masker_gff`), found at
  `/global/cfs/cdirs/plantbox/annotation/<Species>/.../0X_jbrowse/[hap]/input.json`. Match by
  `makeJbrowseName(species_name, version)` = `species[0] + re.sub(r"[.\-]","_",
  " ".join(species.split()[1:]).replace("'","").replace(" ","")+"_"+version)`.

## The tool
`/pscratch/sd/p/phillips/mkjb/repair_repeatmasker.py` (resolver is exact-only; public via
proteome_id, private via `_rmrepair/private_manifest.tsv`). It: detects broken (RM trackData
attrs ∩ {class,classification,target,name,alias} = ∅) → resolves exact source → normalizes
col9 GFF2→GFF3 (`normalize_repeat_gff.pl`) → `shifter flatfile-to-json --gff --compress
--trackType CanvasFeatures` → verifies class present → backs up old track to
`_rmrepair/rm_backups/<sn>/` → atomically swaps ONLY `tracks/RepeatMasker/` via `ssh dtn01`
(/global/dna is read-only on login nodes; dtn01 is rw, auth via on-disk `~/.ssh/nersc`).
Idempotent (already-fixed browsers skip). trackList/refSeqs/names/other tracks untouched.

## Run it (from /pscratch/sd/p/phillips/mkjb, `module load python` first)
- Dry-run one (build+verify, no deploy): `python3 repair_repeatmasker.py <shortname>`
- Deploy one: `python3 repair_repeatmasker.py --deploy <shortname>`
- Batch (parallel, in screen on a recorded login node):
  `cat targets.txt | xargs -P 8 -I{} python3 -u repair_repeatmasker.py --deploy {}`
  (see `backfill_public.sh` / `backfill_private.sh` templates).

## Private source not on cfs?
A few private sources live only on dori `/clusterfs` (dori has no cfs access). scp them to
`_rmrepair/dori_sources/` over the dori ssh mux (`~/.claude/dori-guide.md`) and point the
manifest row at the staged copy (category `STAGED`). To (re)build the private manifest, parse
the cfs annotation-tree `input.json`s (see `_rmrepair/cfs_jbp_paths.txt` /
`repeatmasker-class-fix` memory).

## Notes / limits
- If the source genuinely has no class attribute (e.g. EDTA-style only `Name`, or `Match`/
  `length`, or ID-only GFF3), `verify_built` fails and it is NOT deployed — there is nothing to
  recover; that is correct, not an error.
- The pipelines themselves are already fixed (public `build_jbrowse.sh`; JBPrivate WDL on
  branch `jlp_dev` via `repeatGff2ToGff3.py` in image
  `jlphillipslbl/jbpythonscripts@sha256:e973b7410e2f562215247946dae33968c145443325253ee971fe92ab805f10a6`),
  so newly-built browsers should not need this — it is for the backlog / stragglers.
