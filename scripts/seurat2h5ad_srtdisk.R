suppressPackageStartupMessages({
  library(Seurat)
  library(srtdisk)
})

log_time <- function(msg) cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S]"), msg, "\n", flush=TRUE)

log_time("Loading Seurat object...")
seurat_obj <- readRDS("/pscratch/sd/p/phillips/GSE152766_Root_Atlas_seu4.rds")
log_time("Object loaded.")
print(seurat_obj)

cat("\nAssays:", paste(Assays(seurat_obj), collapse=", "), "\n")
cat("Default assay:", DefaultAssay(seurat_obj), "\n")
cat("Reductions:", paste(names(seurat_obj@reductions), collapse=", "), "\n")
cat("Cells:", ncol(seurat_obj), "\n")
cat("Features:", nrow(seurat_obj), "\n")

# Fix SCTModel objects missing median_umi slot
# The RDS was created with older Seurat, but our Seurat v5 class definition includes median_umi.
# readRDS loads the object with the new class def, but the slot data is missing.
# We populate it from cell.attributes$umi as per the documented workaround.
log_time("Fixing SCTModel median_umi slots...")
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
          cat(sprintf("  %s/%s: median_umi already set (%.2f)\n", assay_name, model_name, existing))
        }, error = function(e) {
          umi_median <- median(slot(model, "cell.attributes")$umi)
          slot(models[[model_name]], "median_umi") <<- umi_median
          cat(sprintf("  %s/%s: populated median_umi = %.2f\n", assay_name, model_name, umi_median))
        })
      }
    }
    slot(assay, "SCTModel.list") <- models
    seurat_obj[[assay_name]] <- assay
  }
}
log_time("SCTModel fix complete.")

# Flatten list-typed metadata columns to simple vectors.
# These columns contain classification results stored as lists. Most cells have a single value,
# but some have ties (2 values) or empty entries (0 values):
#   celltype.ID: 1 cell with 2 values (tie: "hair cells;non-hair cells")
#   celltype.pvalue: 1 cell with 2 identical p-values (same tie)
#   Rad.ID: 1 cell with 2 values (tie: "Xylem Pole Pericycle;Phloem Pole Pericycle")
#   Rad.pvalue: 1 cell with 2 identical p-values (same tie)
#   ploidy.pvalue.P: 29 cells with empty entries (no classification)
# Strategy: join multi-element entries with ";", convert empty to NA.
log_time("Flattening list-typed metadata columns...")
meta <- seurat_obj@meta.data
list_cols <- sapply(meta, is.list)
if (any(list_cols)) {
  for (col in names(list_cols)[list_cols]) {
    lengths <- sapply(meta[[col]], length)
    n_multi <- sum(lengths > 1)
    n_empty <- sum(lengths == 0)
    cat(sprintf("  Flattening %s: %d single, %d multi-value, %d empty\n",
                col, sum(lengths == 1), n_multi, n_empty))
    is_numeric_col <- grepl("pvalue|cor$|score", col, ignore.case = TRUE)
    meta[[col]] <- sapply(meta[[col]], function(x) {
      if (is.null(x) || length(x) == 0) return(NA)
      if (length(x) == 1) return(x)
      # Multi-element: for numeric columns, take first if all identical, otherwise warn and take first
      if (is_numeric_col) {
        vals <- as.numeric(x)
        if (length(unique(vals)) == 1) return(vals[1])
        cat(sprintf("    WARNING: non-identical multi-values in numeric col: %s\n", paste(x, collapse=", ")))
        return(vals[1])
      }
      # For character columns (like cell type IDs), join ties with ";"
      return(paste(x, collapse = ";"))
    })
    if (is_numeric_col) {
      meta[[col]] <- as.numeric(meta[[col]])
      cat(sprintf("    -> numeric, NA count: %d\n", sum(is.na(meta[[col]]))))
    } else {
      cat(sprintf("    -> character, sample: %s\n", paste(head(meta[[col]], 3), collapse=", ")))
    }
  }
  seurat_obj@meta.data <- meta
  log_time(sprintf("Flattened %d list-typed columns.", sum(list_cols)))
} else {
  log_time("No list-typed columns found.")
}

# Patch srtdisk's WriteH5Group for lists to avoid HDF5 attribute header overflow.
# The original writes group names as an HDF5 attribute ("names"), which is stored inline
# in the object header (64KB limit). For large lists this overflows.
# Fix: write names as a dataset instead of an attribute when they're too large.
log_time("Patching WriteH5Group for list to handle large name lists...")
original_method <- getMethod("WriteH5Group", "list", where = asNamespace("srtdisk"))
patched_body <- function(x, name, hgroup, verbose = TRUE) {
  if (is.data.frame(x = x)) {
    WriteH5Group(x = x, name = name, hgroup = hgroup, verbose = verbose)
  } else if (is.list(x = x)) {
    x <- srtdisk:::PadNames(x = x)
    xgroup <- hgroup$create_group(name = name)
    for (i in seq_along(along.with = x)) {
      WriteH5Group(x = x[[i]], name = names(x = x)[i], hgroup = xgroup, verbose = verbose)
    }
    if (!is.null(x = names(x = x)) && length(x = names(x = x))) {
      name_values <- intersect(x = names(x = x), y = names(x = xgroup))
      # Use dataset instead of attribute to avoid header overflow
      tryCatch(
        xgroup$create_attr(attr_name = "names", robj = name_values,
                           dtype = srtdisk:::GuessDType(x = names(x = x)[1])),
        error = function(e) {
          cat("  Note: names attribute too large for HDF5 header, writing as dataset\n")
          xgroup$create_dataset(name = "__names__", robj = name_values,
                                dtype = srtdisk:::GuessDType(x = names(x = x)[1]))
        }
      )
    }
    if (!all(class(x = x) == "list")) {
      tryCatch(
        xgroup$create_attr(attr_name = "s3class", robj = class(x = x),
                           dtype = srtdisk:::GuessDType(x = class(x = x)[1])),
        error = function(e) {
          cat("  Note: s3class attribute too large, writing as dataset\n")
          xgroup$create_dataset(name = "__s3class__", robj = class(x = x),
                                dtype = srtdisk:::GuessDType(x = class(x = x)[1]))
        }
      )
    }
  } else if (is.vector(x = x) && !is.null(x = names(x = x))) {
    gzip <- srtdisk:::GetCompressionLevel()
    if (gzip > 0L && length(x) > 64L) {
      hgroup$create_dataset(name = paste0(name, "__names__"), robj = names(x = x),
                            dtype = srtdisk:::GuessDType(x = names(x = x)))
      hgroup$create_dataset(name = name, robj = x, dtype = srtdisk:::GuessDType(x = x),
                            gzip_level = gzip)
    } else {
      hgroup$create_dataset(name = paste0(name, "__names__"), robj = names(x = x),
                            dtype = srtdisk:::GuessDType(x = names(x = x)))
      hgroup$create_dataset(name = name, robj = x, dtype = srtdisk:::GuessDType(x = x))
    }
  } else if (!is.null(x = x)) {
    gzip <- srtdisk:::GetCompressionLevel()
    if (gzip > 0L && length(x) > 64L) {
      hgroup$create_dataset(name = name, robj = x, dtype = srtdisk:::GuessDType(x = x),
                            gzip_level = gzip)
    } else {
      hgroup$create_dataset(name = name, robj = x, dtype = srtdisk:::GuessDType(x = x))
    }
  }
  return(invisible(x = NULL))
}
setMethod("WriteH5Group", "list", patched_body)
log_time("Patch applied.")

# Convert directly to h5ad (full object, no modifications beyond the median_umi fix)
h5ad_path <- "/pscratch/sd/p/phillips/GSE152766_Root_Atlas.h5ad"
log_time(paste("Converting to h5ad:", h5ad_path))
SeuratToH5AD(seurat_obj, file = h5ad_path, overwrite = TRUE)
log_time("h5ad conversion complete!")
system(paste("ls -lh", h5ad_path))
