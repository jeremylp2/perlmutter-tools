# Seurat RDS to h5ad Conversion Guide (Perlmutter)

## Overview

Converting large Seurat `.rds` objects to `.h5ad` (AnnData) format for CELLxGENE viewing. This guide covers pitfalls encountered converting `GSE152766_Root_Atlas_seu4.rds` (49GB compressed, 110K cells, 3 assays).

## CRITICAL: Inspect the object FIRST

Before attempting any conversion, run a full inventory of the Seurat object. Conversion is slow (loading alone takes ~6 min for this object), so you must detect problems before starting. Run `seurat_full_inventory.R` (in this directory) on an interactive node:

```bash
salloc -A m342 -q interactive -t 1:00:00 --constraint=cpu --nodes=1 --exclusive \
  srun Rscript /pscratch/sd/p/phillips/seurat_full_inventory.R
```

### What to check in the inventory:

1. **SCTAssay presence**: Check if any assay has class `SCTAssay`. If so, check the SCTModel objects for missing `median_umi` slots (see Pitfall #1).

2. **List-typed metadata columns**: Check `obs` for columns with `class=list`. These break HDF5 serialization (see Pitfall #3).

3. **Object size**: The `integrated` assay may have a dense `scale.data` matrix (17,513 × 110,427 = ~15GB). Factor this into time and disk estimates.

4. **Assay count and types**: Multiple assays (RNA, SCT, integrated) all get serialized. The RNA `data` slot may be identical to `counts` (never normalized) — check this.

## Environment Setup

### R packages (local install to pscratch)

```bash
module load R cray-hdf5
export R_PROFILE_USER=/pscratch/sd/p/phillips/.Rprofile_install
```

Packages are installed in `/pscratch/sd/p/phillips/R_libs`. Key packages:
- `Seurat` 5.x (from CRAN)
- `srtdisk` (from `mianaz/srtdisk` on GitHub — Seurat v5 compatible fork of SeuratDisk)
- `hdf5r` (linked against Perlmutter's cray-hdf5)

### Why srtdisk, not SeuratDisk?

**SeuratDisk is abandoned and incompatible with Seurat v5.** Seurat v5 made `GetAssayData(slot=...)` defunct (not just deprecated — it throws a hard error). SeuratDisk still uses this API. The `srtdisk` fork (github.com/mianaz/srtdisk) fixes this.

### R library path gotcha

**`~/.Rprofile` on this account used to override `.libPaths()` and wipe `R_LIBS_USER`.**  It has been fixed (the offending line pointed to a nonexistent directory and was removed). But if library path issues recur:

- `R_LIBS_USER` can be silently ignored if `.Rprofile` calls `.libPaths()` with a single path (replaces rather than prepends).
- `install.packages` spawns subprocesses for byte-compilation that inherit `R_PROFILE_USER` but NOT the parent session's `.libPaths()`. So even if `.libPaths()` is correct in your main R session, subprocesses may not see it.
- **Fix**: Use `R_PROFILE_USER` pointing to a file that calls `.libPaths(c("/pscratch/sd/p/phillips/R_libs", .libPaths()))`.
- **Diagnosis**: If packages compile successfully but fail at "lazy loading" saying a dependency is "not found" even though it's installed — this is the library path issue.

## Pitfall #1: SCTModel `median_umi` slot

### Symptom
```
Error in slot(object = object, name = x) :
  no slot of name "median_umi" for this object of class "SCTModel"
```

### Cause
The RDS was created with an older Seurat where SCTModel didn't have `median_umi`. Our Seurat v5 class definition includes it. When `readRDS` loads the object, the SCTModel gets the new class definition with `median_umi` in `slotNames()`, but the actual stored data doesn't have it populated. The serializer iterates `slotNames()` and crashes on the empty slot.

### Fix
After loading, populate `median_umi` on all SCTModel objects:

```r
for (assay_name in Assays(seurat_obj)) {
  assay <- seurat_obj[[assay_name]]
  if (is(assay, "SCTAssay")) {
    models <- slot(assay, "SCTModel.list")
    for (model_name in names(models)) {
      model <- models[[model_name]]
      if (!is.null(model) && is(model, "SCTModel")) {
        tryCatch({
          existing <- slot(model, "median_umi")
          if (is.null(existing) || length(existing) == 0 || is.na(existing)) stop("empty")
        }, error = function(e) {
          umi_median <- median(slot(model, "cell.attributes")$umi)
          slot(models[[model_name]], "median_umi") <<- umi_median
        })
      }
    }
    slot(assay, "SCTModel.list") <- models
    seurat_obj[[assay_name]] <- assay
  }
}
```

In this object there are 16 SCTModel objects in the SCT assay and 1 in the integrated assay (which is also an SCTAssay).

## Pitfall #2: HDF5 attribute header overflow

### Symptom
```
Error in xgroup$create_attr(attr_name = "names", robj = intersect(...)) :
  HDF5-API Errors: unable to create attribute
```

### Cause
`srtdisk`'s `WriteH5Group` method for lists writes group sub-item names as an HDF5 **attribute**. HDF5 attributes are stored inline in the object header (~64KB limit). When serializing deeply nested S4 objects (like SCTModel with feature.attributes, cell.attributes, etc.), the accumulated attributes overflow this limit.

### Fix
Monkey-patch the `WriteH5Group` list method to catch the error and fall back to writing names as a dataset:

```r
patched_body <- function(x, name, hgroup, verbose = TRUE) {
  # ... (see seurat2h5ad_srtdisk.R for full implementation)
  # Key change: wrap create_attr in tryCatch, fall back to create_dataset
  tryCatch(
    xgroup$create_attr(attr_name = "names", robj = name_values, ...),
    error = function(e) {
      xgroup$create_dataset(name = "__names__", robj = name_values, ...)
    }
  )
}
setMethod("WriteH5Group", "list", patched_body)
```

## Pitfall #3: List-typed metadata columns

### Symptom
Either:
- `write.csv`: `unimplemented type 'list' in 'EncodeElement'`
- During h5Seurat→h5ad: `object of type 'environment' is not subsettable`

### Cause
5 metadata columns in this object are R list-type instead of simple vectors:
- `celltype.ID` — cell type labels (strings)
- `celltype.pvalue` — p-values (numeric)
- `Rad.ID` — radial identity labels (strings)
- `Rad.pvalue` — p-values (numeric)
- `ploidy.pvalue.P` — p-values (numeric)

Each cell has a single value wrapped in a list (artifact of `lapply` output assigned to metadata). WriteH5Group serializes these as HDF5 groups rather than datasets, which breaks the h5Seurat→h5ad `TransferDF` step.

### Fix
Flatten before conversion:

```r
meta <- seurat_obj@meta.data
list_cols <- sapply(meta, is.list)
for (col in names(list_cols)[list_cols]) {
  meta[[col]] <- unlist(meta[[col]])
}
seurat_obj@meta.data <- meta
```

### Important
These are NOT being dropped — the data is preserved. `unlist()` on a list of single-element vectors produces the same values as a simple vector. Verify with `head()` before and after.

## Pitfall #4: RNA data slot identical to counts

The RNA assay's `data` slot was never normalized — it's identical to `counts`. The actual normalized data is in the SCT and integrated assays. For CELLxGENE, the expression color scale will use whatever is in `X`. If `X` ends up being raw counts, you may want to log-normalize in a post-processing step:

```python
# Standard Seurat NormalizeData equivalent
import numpy as np
from scipy.sparse import diags
total = np.array(adata.X.sum(axis=1)).flatten()
total[total == 0] = 1.0
adata.X = diags(10000.0 / total).dot(adata.X)
adata.X.data = np.log1p(adata.X.data)
```

## Do NOT use Shifter containers for this

Shifter images are for WDL pipelines. For interactive R/Python work, use `module load R` and local package installs. See CLAUDE.md.

## Conversion script

The current conversion script is `/pscratch/sd/p/phillips/seurat2h5ad_srtdisk.R`. It includes all three fixes above (median_umi, list flattening, HDF5 patch).

Run via:
```bash
module load R cray-hdf5
export R_PROFILE_USER=/pscratch/sd/p/phillips/.Rprofile_install
salloc -A m342 -q interactive -t 4:00:00 --constraint=cpu --nodes=1 --exclusive \
  srun Rscript /pscratch/sd/p/phillips/seurat2h5ad_srtdisk.R
```

## Object inventory reference (from seurat_full_inventory.log)

- **3 assays**: RNA (28,958 genes, counts+data identical, sparse 11.5% density), SCT (24,997 genes, SCTAssay with 16 models), integrated (17,513 genes, SCTAssay with 1 model, 100% dense data slot)
- **5 reductions**: pca (50d + loadings), umap (2d), umap_50 (50d), umap_3D (2d), umap_2D (2d)
- **2 graphs**: integrated_nn, integrated_snn (110,427 × 110,427 each)
- **104 metadata columns**: 35 character, 23 factor, 6 integer, 5 list, 35 numeric
- **6 commands**: FindIntegrationAnchors, withCallingHandlers, RunPCA, FindNeighbors, FindClusters, RunUMAP
- **1 tool**: Integration (IntegrationData)
- **No images, empty misc**
