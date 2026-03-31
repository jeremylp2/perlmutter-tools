suppressPackageStartupMessages(library(Seurat))

log_time <- function(msg) cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S]"), msg, "\n", flush=TRUE)

log_time("Loading Seurat object...")
obj <- readRDS("/pscratch/sd/p/phillips/GSE152766_Root_Atlas_seu4.rds")
log_time("Object loaded.")

cat("\n========================================\n")
cat("FULL SEURAT OBJECT INVENTORY\n")
cat("========================================\n\n")

# --- Top-level summary ---
cat("=== TOP-LEVEL SUMMARY ===\n")
print(obj)

# --- All slot names ---
cat("\n=== SLOT NAMES ===\n")
cat(paste(slotNames(obj), collapse=", "), "\n")

# --- Assays: full detail ---
cat("\n=== ASSAYS ===\n")
for (assay_name in Assays(obj)) {
  cat(sprintf("\n--- Assay: %s ---\n", assay_name))
  assay <- obj[[assay_name]]
  cat("  Class:", paste(class(assay), collapse="/"), "\n")
  cat("  Slot names:", paste(slotNames(assay), collapse=", "), "\n")

  # Check each data slot
  for (slot_name in c("counts", "data", "scale.data")) {
    tryCatch({
      mat <- GetAssayData(obj, assay=assay_name, slot=slot_name)
      cat(sprintf("  %s: %d x %d", slot_name, nrow(mat), ncol(mat)))
      if (inherits(mat, "dgCMatrix") || inherits(mat, "dgRMatrix") || inherits(mat, "dgTMatrix")) {
        cat(sprintf(" (sparse, %d nonzeros, %.1f%% density)", length(mat@x), 100*length(mat@x)/(as.numeric(nrow(mat))*ncol(mat))))
      } else {
        cat(" (dense)")
      }
      # Check if counts == data
      if (slot_name == "data" && assay_name == "RNA") {
        counts_mat <- GetAssayData(obj, assay=assay_name, slot="counts")
        if (identical(counts_mat, mat)) {
          cat(" *** IDENTICAL TO COUNTS ***")
        } else {
          cat(" (differs from counts)")
        }
      }
      cat(sprintf(", dtype=%s", typeof(mat@x)), "\n")
    }, error = function(e) {
      cat(sprintf("  %s: NOT PRESENT (%s)\n", slot_name, conditionMessage(e)))
    })
  }

  # Variable features
  vf <- tryCatch(VariableFeatures(obj, assay=assay_name), error=function(e) character(0))
  cat(sprintf("  Variable features: %d\n", length(vf)))

  # Key
  cat(sprintf("  Key: %s\n", Key(assay)))

  # Check for SCTModel.list (SCTAssay)
  if (is(assay, "SCTAssay")) {
    cat("  *** This is an SCTAssay ***\n")
    tryCatch({
      models <- slot(assay, "SCTModel.list")
      cat(sprintf("  SCTModel.list: %d models\n", length(models)))
      for (m_name in names(models)) {
        model <- models[[m_name]]
        cat(sprintf("    Model '%s': class=%s, slots=%s\n", m_name,
                    paste(class(model), collapse="/"),
                    paste(slotNames(model), collapse=", ")))
      }
    }, error = function(e) cat("  SCTModel.list: error accessing -", conditionMessage(e), "\n"))
  }

  # Feature-level metadata (meta.features)
  tryCatch({
    mf <- assay@meta.features
    if (ncol(mf) > 0) {
      cat(sprintf("  meta.features: %d genes x %d columns: %s\n", nrow(mf), ncol(mf),
                  paste(colnames(mf), collapse=", ")))
    } else {
      cat("  meta.features: empty\n")
    }
  }, error = function(e) cat("  meta.features: error -", conditionMessage(e), "\n"))

  # misc
  tryCatch({
    m <- slot(assay, "misc")
    if (length(m) > 0) {
      cat(sprintf("  misc: %d items: %s\n", length(m), paste(names(m), collapse=", ")))
    } else {
      cat("  misc: empty\n")
    }
  }, error = function(e) {})
}

# --- Reductions ---
cat("\n=== REDUCTIONS ===\n")
for (red_name in names(obj@reductions)) {
  red <- obj@reductions[[red_name]]
  emb <- Embeddings(red)
  cat(sprintf("  %s: %d cells x %d dims", red_name, nrow(emb), ncol(emb)))
  # Check loadings
  loadings <- tryCatch(Loadings(red), error=function(e) matrix(nrow=0, ncol=0))
  if (nrow(loadings) > 0) {
    cat(sprintf(", loadings: %d x %d", nrow(loadings), ncol(loadings)))
  }
  # stdev
  stdev <- tryCatch(Stdev(red), error=function(e) numeric(0))
  if (length(stdev) > 0) {
    cat(sprintf(", stdev: %d values", length(stdev)))
  }
  cat(sprintf(", key=%s", Key(red)))
  cat("\n")
}

# --- Graphs ---
cat("\n=== GRAPHS ===\n")
if (length(obj@graphs) > 0) {
  for (g_name in names(obj@graphs)) {
    g <- obj@graphs[[g_name]]
    cat(sprintf("  %s: %d x %d, class=%s\n", g_name, nrow(g), ncol(g), paste(class(g), collapse="/")))
  }
} else {
  cat("  (none)\n")
}

# --- Neighbors ---
cat("\n=== NEIGHBORS ===\n")
if (length(obj@neighbors) > 0) {
  for (n_name in names(obj@neighbors)) {
    cat(sprintf("  %s: class=%s\n", n_name, paste(class(obj@neighbors[[n_name]]), collapse="/")))
  }
} else {
  cat("  (none)\n")
}

# --- Commands ---
cat("\n=== COMMANDS ===\n")
if (length(obj@commands) > 0) {
  cat(sprintf("  %d commands logged:\n", length(obj@commands)))
  for (cmd_name in names(obj@commands)) {
    cat(sprintf("    %s\n", cmd_name))
  }
} else {
  cat("  (none)\n")
}

# --- Tools ---
cat("\n=== TOOLS ===\n")
if (length(obj@tools) > 0) {
  cat(sprintf("  %d tools:\n", length(obj@tools)))
  for (t_name in names(obj@tools)) {
    t <- obj@tools[[t_name]]
    cat(sprintf("    %s: class=%s\n", t_name, paste(class(t), collapse="/")))
  }
} else {
  cat("  (none)\n")
}

# --- Misc ---
cat("\n=== MISC ===\n")
if (length(obj@misc) > 0) {
  cat(sprintf("  %d items:\n", length(obj@misc)))
  for (m_name in names(obj@misc)) {
    m <- obj@misc[[m_name]]
    cat(sprintf("    %s: class=%s", m_name, paste(class(m), collapse="/")))
    if (is.data.frame(m)) cat(sprintf(", %d x %d", nrow(m), ncol(m)))
    if (is.matrix(m)) cat(sprintf(", %d x %d", nrow(m), ncol(m)))
    if (is.vector(m) && !is.list(m)) cat(sprintf(", length=%d", length(m)))
    cat("\n")
  }
} else {
  cat("  (none)\n")
}

# --- Cell metadata detail ---
cat("\n=== CELL METADATA (obs) ===\n")
cat(sprintf("  %d cells x %d columns\n", nrow(obj@meta.data), ncol(obj@meta.data)))
for (col in colnames(obj@meta.data)) {
  vals <- obj@meta.data[[col]]
  cls <- paste(class(vals), collapse="/")
  typ <- typeof(vals)
  nnull <- sum(is.na(vals))
  nuniq <- length(unique(vals))
  is_lst <- is.list(vals)

  info <- sprintf("  %-35s class=%-12s typeof=%-10s nulls=%-6d uniq=%-6d", col, cls, typ, nnull, nuniq)
  if (is_lst) info <- paste(info, "*** LIST ***")
  cat(info, "\n")
}

# --- Images ---
cat("\n=== IMAGES ===\n")
if (length(obj@images) > 0) {
  cat(sprintf("  %d images\n", length(obj@images)))
} else {
  cat("  (none)\n")
}

# --- Project name ---
cat("\n=== PROJECT ===\n")
cat(sprintf("  %s\n", obj@project.name))

# --- Active ident ---
cat("\n=== ACTIVE IDENT ===\n")
cat(sprintf("  %d levels: %s\n", length(levels(Idents(obj))), paste(head(levels(Idents(obj)), 20), collapse=", ")))

log_time("Inventory complete.")
