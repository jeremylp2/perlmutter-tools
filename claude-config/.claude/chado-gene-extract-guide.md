# CHADO Gene Extraction to MongoDB Guide

Extracts gene records from the plant_chado PostgreSQL database as JSON files and loads them into the `phytozome_v14` MongoDB collection.

## Pipeline Overview

```
plant_chado (PostgreSQL, plant-db-7) → JSON tars on CFS → phytozome_v14 (MongoDB, plant-db-4)
```

- **Extraction script**: `~/git/compgen/data_wrangling/CHADOio/extractors/getGeneJSON_P14_onScratch.sh`
- **Output directory**: `/global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/`
- **Loader script**: `/global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/loadMongoGenes.sh`

## Step 1: Extract Gene JSON from CHADO

### Perl environment requirement

The extractor Perl script (`getChadoGeneRecordsExonCached.pl`) requires `DBD::Pg`. This is **not** available in system Perl. You must prepend the `cperl` conda env to PATH:

```bash
export PATH=/global/cfs/cdirs/jgisftwr/plant/phillips/conda/envs/cperl/bin:$PATH
```

**Do not** use `conda activate` — it is not available in non-interactive shells (screen, scripts). Prepending to PATH is the reliable method.

### Running the extraction

Always run in a detached screen session. The jobs run on `$SCRATCH` and can take tens of minutes per proteome.

```bash
screen -dmS getgenes bash -c '
export PATH=/global/cfs/cdirs/jgisftwr/plant/phillips/conda/envs/cperl/bin:$PATH
echo "Running on $(hostname)"
bash ~/git/compgen/data_wrangling/CHADOio/extractors/getGeneJSON_P14_onScratch.sh 862,863,864 \
  2>&1 | tee /global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/NOHUPS/getgenes_run.log
echo "Script finished"
'
```

- Accepts a comma-separated list of proteome IDs as the only argument
- Skips any proteome that already has a `genes_N.tar` in `$SCRATCH` or in the output dir
- Throttles to ~6 concurrent Perl jobs automatically
- Logs per-proteome to `$SCRATCH/nohup.N.out`; moves logs to `NOHUPS/` on completion

### Monitoring progress

```bash
# Check overall log (on login15 where screen runs)
tail -f /global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/NOHUPS/getgenes_run.log

# Check a specific proteome (while running, log is in $SCRATCH)
tail $SCRATCH/nohup.862.out

# Confirm real progress (non-empty JSON files in per-proteome scratch dir)
head -3 $SCRATCH/nohup.862.out   # should show "found N records" if working
ls $SCRATCH/862/ | wc -l         # growing number of .json files

# Check output tars (after completion)
ls -lh /global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/genes_862.tar
tar -tvf /global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/genes_862.tar | wc -l
```

**A successful run produces tars with batched JSON files — typically ~150–250 files per proteome (the extractor batches ~500 records per JSON), not thousands.** A 2-byte `N_gene_0.json` means the Perl script failed silently — check the nohup log.

**Sanity-check by total record count, not file count.** Use the perl's own log line `Processed N genes.` (final, no ellipsis) as the source of truth. Example: 864 (Boechera sierraensis) = 79,354 genes processed → 159 JSON files in the tar → ~890 MB compressed.

A naive wrapper that asserts `JSON_COUNT >= 1000` will spuriously fail on every proteome. Use `tar -tf … | wc -l` for record count if you must validate; or read the final "Processed N genes." line from `nohup.$p.out`.

The default `getGeneJSON_P14_onScratch.sh` wrapper backgrounds the perl with `&` and returns immediately. To wait synchronously (so your screen session stays alive), call the underlying perl directly: `$CODEDIR/getChadoGeneRecordsExonCached.pl plant_chado $j $j/ 1 >> nohup.$j.out 2>&1`.

### Verifying completion

```bash
for p in 862 863 864; do
  echo "$p: $(tar -tvf /global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/genes_$p.tar 2>/dev/null | wc -l) files"
done
```

## Step 2: Load JSON Tars into MongoDB

Script: `/global/cfs/cdirs/plantbox/CHADO_GENE_v14/NEW/loadMongoGenes.sh`

Operates on all `genes_*.tar` files in the current directory. Run from the output directory.

**Known issues with loadMongoGenes.sh:**
- Credentials are hardcoded — should be replaced with config-file reads (see mongo-guide.md)
- Drops the existing collection before importing (no backup)
- No error handling — failures are silent

## Database Reference

| System | Host | DB | Purpose |
|--------|------|----|---------|
| PostgreSQL | plant-db-7.jgi.lbl.gov | plant_chado | Source: gene records |
| MongoDB | plant-db-4.jgi.lbl.gov | phytozome_v14 | Destination: gene JSON docs |

Config: `~/.confFile` sections `[plant_chado]` (PostgreSQL) and `[mongodb_genes]` (MongoDB).
