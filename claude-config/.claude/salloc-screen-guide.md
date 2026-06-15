# salloc + screen pattern for fire-and-forget interactive jobs

Use this pattern to run jobs on compute nodes that don't need constant interaction but fit within the interactive queue limits (≤4 hours, 1 node).

## The pattern

```bash
screen -dmS jobname bash -c "
salloc -A m342 -q interactive -t 4:00:00 --constraint=cpu --nodes=1 --exclusive \
  srun /path/to/command args \
  > /pscratch/sd/p/phillips/jobname.log 2>&1
"
```

This:
1. Creates a detached screen session (`-dmS`)
2. Inside it, `salloc` requests a node from the interactive queue
3. `srun` runs your command on the allocated node
4. All output goes to a log file
5. Survives SSH disconnects and Claude Code session exits

## Checking status

```bash
# Is the screen session alive?
screen -ls | grep jobname

# What node is it on?
squeue -u phillips

# Read the output
tail -f /pscratch/sd/p/phillips/jobname.log
```

## Important: unbuffered output

Python and R buffer stdout when piped through `srun`. Use:
- Python: `python3 -u script.py` (unbuffered) or `flush=True` in print calls
- R: `cat(..., flush=TRUE)` — though R is less aggressive about buffering

Without this, the log file stays empty until the process exits.

## Note on srun

`srun` is needed in the `screen -dmS` pattern because `salloc` with a command runs that command on the login node unless `srun` dispatches it to the compute node. When you run `salloc` interactively (no command), Perlmutter gives you a shell directly on the compute node — no `srun` needed.

## When NOT to use this

- Jobs longer than 4 hours → use `sbatch` instead
- Jobs needing multiple nodes → use `sbatch` with proper `srun` dispatching
- Truly interactive work (debugging, exploring) → use `salloc` directly in your terminal (`getint` alias)

## Example: R script on a compute node

```bash
screen -dmS convert bash -c "
module load R cray-hdf5
export R_PROFILE_USER=/pscratch/sd/p/phillips/.Rprofile_install
salloc -A m342 -q interactive -t 4:00:00 --constraint=cpu --nodes=1 --exclusive \
  srun Rscript /pscratch/sd/p/phillips/my_script.R \
  > /pscratch/sd/p/phillips/convert.log 2>&1
"
```

## Example: chaining steps

```bash
screen -dmS pipeline bash -c "
# Step 1
salloc -A m342 -q interactive -t 4:00:00 --constraint=cpu --nodes=1 --exclusive \
  srun Rscript /pscratch/sd/p/phillips/step1.R \
  > /pscratch/sd/p/phillips/step1.log 2>&1

# Step 2 (only if step 1 succeeded)
if grep -q 'ALL DONE' /pscratch/sd/p/phillips/step1.log; then
  salloc -A m342 -q interactive -t 4:00:00 --constraint=cpu --nodes=1 --exclusive \
    srun python3 -u /pscratch/sd/p/phillips/step2.py \
    > /pscratch/sd/p/phillips/step2.log 2>&1
fi
"
```
