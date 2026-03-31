---
name: seurat-to-h5ad
description: Convert a Seurat .rds object to .h5ad format for CELLxGENE. Runs pre-flight inspection, detects and fixes known pitfalls, then converts. Use when the user asks to convert Seurat to h5ad, anndata, or prepare data for CELLxGENE.
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent
argument-hint: [path-to-rds-file]
---

# Seurat to h5ad Conversion

Convert a Seurat `.rds` file to `.h5ad` format for CELLxGENE viewing.

**Read the full guide first**: `/pscratch/sd/p/phillips/seurat_to_h5ad_guide.md`

The RDS file to convert is: `$ARGUMENTS`

## CRITICAL: Pre-flight before conversion

You MUST inspect the object and run a subset dry-run BEFORE attempting the full conversion. Loading a large Seurat object takes minutes and conversion takes hours — you cannot afford to discover issues mid-conversion.

### Step 1: Environment setup

```bash
module load R cray-hdf5
export R_PROFILE_USER=/pscratch/sd/p/phillips/.Rprofile_install
```

R packages (Seurat, srtdisk, hdf5r) are in `/pscratch/sd/p/phillips/R_libs`. If they need reinstalling, see the guide. Key gotcha: `~/.Rprofile` can silently override `R_LIBS_USER` — use `R_PROFILE_USER` instead.

### Step 2: Full object inventory

Write and run an inventory script on an interactive node that reports:
- All assays with class, dimensions, slot contents (counts, data, scale.data)
- Whether any assay is `SCTAssay` — if so, list all SCTModel objects and their slot names
- All reductions with dimensions
- All metadata columns with class, typeof, null count, unique count
- Flag any `class=list` columns
- Graphs, neighbors, commands, tools, misc contents
- Active ident levels

### Step 3: Deep inspection of anomalies

For EVERY anomaly found in Step 2, drill into the actual values before writing any fix:

- **List-typed columns**: Run `table(sapply(col, length))` to check for multi-element entries (ties) and empty entries. Show example values for any non-length-1 entries.
- **SCTAssay with SCTModel objects**: Check if `median_umi` slot is populated or empty. Test with `tryCatch(slot(model, "median_umi"), error=function(e) "MISSING")`.
- **Identical counts/data slots**: Compare with `identical(GetAssayData(obj, layer="counts"), GetAssayData(obj, layer="data"))` to detect unnormalized data.

### Step 4: Write fixes and validate on subset

Write ALL fixes into the conversion script, then validate on a 100-cell subset:

```r
small <- subset(seurat_obj, cells = colnames(seurat_obj)[1:100])
# Apply all fixes to small object...
SeuratToH5AD(small, file = "test_small.h5ad", overwrite = TRUE)
```

This catches serialization errors in seconds instead of hours. Do NOT proceed to full conversion until the subset succeeds.

### Step 5: Validate the subset h5ad

```python
import anndata as ad
adata = ad.read_h5ad("test_small.h5ad")
print(adata)  # Should show X, obs, var, obsm, layers
```

### Step 6: Full conversion

Only after subset validation passes, run the full conversion on an interactive node. Always run in a detached screen session:

```bash
screen -dmS convert bash -c "bash /path/to/convert_script.sh"
```

## Known pitfalls (apply fixes as needed)

### 1. SCTModel `median_umi` — populate missing slots
Objects created with older Seurat lack this slot. Fix by computing from `cell.attributes$umi`.

### 2. List-typed metadata — flatten with proper edge case handling
Some cells may have ties (multiple values) or empty entries. Use `sapply` with explicit handling:
- length=0 → NA
- length=1 → the value
- length>1 → paste with ";" separator
- Convert p-value columns back to numeric after flattening

### 3. HDF5 attribute header overflow — patch WriteH5Group
`srtdisk`'s list serializer writes names as HDF5 attributes (64KB header limit). Patch to fall back to datasets on overflow.

### 4. SeuratDisk is dead — use srtdisk
SeuratDisk is abandoned and incompatible with Seurat v5. Use `mianaz/srtdisk` from GitHub.

### 5. RNA data may be unnormalized
If RNA data==counts, the h5ad X will contain raw counts. May need post-conversion log-normalization.

## Reference files

- Guide: `/pscratch/sd/p/phillips/seurat_to_h5ad_guide.md`
- Inventory script: `/pscratch/sd/p/phillips/seurat_full_inventory.R`
- Working conversion script: `/pscratch/sd/p/phillips/seurat2h5ad_srtdisk.R`
- R libraries: `/pscratch/sd/p/phillips/R_libs`
- R profile for installs: `/pscratch/sd/p/phillips/.Rprofile_install`
