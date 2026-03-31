#!/bin/bash
echo "Running on $(hostname)"
echo "Started at $(date)"

module load R cray-hdf5
export R_LIBS_USER=/pscratch/sd/p/phillips/R_libs
# ~/.Rprofile overrides .libPaths() and wipes R_LIBS_USER — write a temp Rprofile that prepends our lib
cat > /pscratch/sd/p/phillips/.Rprofile_install << 'RPEOF'
.libPaths(c("/pscratch/sd/p/phillips/R_libs", .libPaths()))
RPEOF
export R_PROFILE_USER=/pscratch/sd/p/phillips/.Rprofile_install

R --no-save --no-restore << 'REOF'
.libPaths(c('/pscratch/sd/p/phillips/R_libs', .libPaths()))
cat("Library paths:\n")
print(.libPaths())
# Clean stale locks
unlink(list.files('/pscratch/sd/p/phillips/R_libs', pattern='^00LOCK', full.names=TRUE), recursive=TRUE)

# Install with Ncpus=1 to avoid lock conflicts
install.packages('Seurat', lib='/pscratch/sd/p/phillips/R_libs', repos='https://cloud.r-project.org', dependencies=TRUE, Ncpus=1)

# Also install SeuratDisk from GitHub
if (!require('remotes', quietly=TRUE)) install.packages('remotes', lib='/pscratch/sd/p/phillips/R_libs', repos='https://cloud.r-project.org')
library(remotes)
install_github('mojaveazure/seurat-disk', lib='/pscratch/sd/p/phillips/R_libs', upgrade='never')

# Verify
library(Seurat)
library(SeuratDisk)
cat('Seurat:', as.character(packageVersion('Seurat')), '\n')
cat('SeuratObject:', as.character(packageVersion('SeuratObject')), '\n')
cat('SeuratDisk:', as.character(packageVersion('SeuratDisk')), '\n')
cat('SCTModel slots:', paste(slotNames(new('SCTModel')), collapse=', '), '\n')
cat('ALL DONE\n')
REOF

echo "Finished at $(date)"
