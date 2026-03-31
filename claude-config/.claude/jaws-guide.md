# JAWS Pipeline Guide
# General lessons for building WDL pipelines on JAWS at JGI

## What is JAWS

JAWS (JGI Analysis Workflows Service) is a workflow execution layer on top of Cromwell.
Key difference from running Cromwell locally: **JAWS stages all input files**. Only files
explicitly listed in the input JSON are available to tasks. Nothing from the local filesystem
is accessible unless it was declared as an input or is baked into a Docker image.

Available compute sites: `perlmutter`, `dori`

**WDL version:** Always use `version 1.0`. WDL 1.1 is not supported by Cromwell in JAWS.

**Execution backend:** JAWS uses HTCondor → SLURM on Perlmutter. You cannot change the backend from HTCondor within JAWS.

---

## Setup

```bash
source ~/jaws-prod.sh   # ALWAYS before using any jaws command
```

---

## Key JAWS Commands

```bash
# Submit
jaws submit --team phytzm --tag <tag> <wdl_file> <input.json> <site>

# Multiple input JSONs (JAWS merges them):
jaws submit --team phytzm --tag <tag> <wdl_file> input1.json input2.json <site>

# Status / monitoring
jaws status <run_id>             # Overall status + output dir
jaws tasks <run_id>              # Per-task detail: timing, cpu_hrs, return_code, sizes
jaws log <run_id>                # State transition log
jaws history --days 30           # Past runs
jaws queue                       # Currently running

# Re-submission
jaws resubmit <run_id>           # Resubmit at same site (re-uses call cache)
jaws submit --no-cache ...       # Disable call caching
jaws submit --overwrite-inputs   # Force re-stage input files that changed on disk

# Sub-workflows: JAWS auto-generates a zip if not provided
jaws submit --sub subwf.zip ...  # Provide manually if needed

# Validation (before submitting)
jaws validate <wdl_file>         # Uses miniwdl

# Generate input template from WDL
jaws inputs <wdl_file>

# Download outputs / logs after completion
jaws download <run_id>
```

Submit returns JSON: `{"run_id": "..."}` — capture it for tracking.

Output directory: `/global/cfs/cdirs/plantbox/phytzm-jaws/<user>/<run_id>/<cromwell_id>/`
Cromwell execution dir (Perlmutter): `/pscratch/sd/j/jaws/perlmutter-prod/cromwell-executions/`

---

## WDL Essentials

Always use **WDL version 1.0**:
```wdl
version 1.0
```

### Input JSON key format
```json
{
  "WorkflowName.input_name": "value",
  "WorkflowName.task_name.input_name": "value"
}
```
Top-level workflow inputs use `WorkflowName.input_name`.
Task-level overrides use `WorkflowName.task_name.input_name`.

### String interpolation in commands
Use `~{variable}` (WDL 1.0 style). In heredoc Python inside a command block,
use `${variable}` to avoid conflicts with shell/Python variable expansion:
```wdl
command {
  python3 <<EOF
  name = "${my_wdl_var}"
  EOF
}
```

### Useful WDL builtins
```wdl
basename(file)           # Filename without directory
basename(file, ".gz")    # Strip extension
read_lines(stdout())     # Capture stdout as Array[String]
select_first([a, b])     # First non-null value
flatten([[a,b],[c]])      # Flatten array of arrays
defined(x)               # Check if optional is set
```

---

## The #1 JAWS Constraint: File Staging

**JAWS only copies files that are:**
1. Declared as `File` inputs in the workflow and listed in the input JSON, OR
2. Outputs from a previous task (passed as task input)

**This means:**
- Scripts used by tasks MUST be inside the Docker image, not on local filesystem
- You cannot reference local paths like `/pscratch/...` in task commands
- Even if a file exists at a path visible from a login node, JAWS tasks can't see it
- To pass a "static" external file, declare it as a `File` workflow input and list it in input JSON
- Exception: `String` inputs can pass paths to files on filesystems the execution node can reach
  (e.g., CFS paths), but this is fragile and bypasses JAWS's staging — use with care

**Output files must be in the execution directory.** JAWS can only collect outputs from
`cromwell-executions/.../execution/`. Files written anywhere else (subdirs not declared as
outputs, `/tmp`, external paths) are invisible to JAWS and will not be transferred back.
Every output file must be explicitly declared in the `output {}` block.

**Workaround for scripts:** Build a custom Docker image containing your scripts.
```dockerfile
FROM python:3.9-slim
RUN pip install biopython
COPY *.py /usr/local/bin/scripts/
RUN chmod +x /usr/local/bin/scripts/*.py
ENV PATH="/usr/local/bin/scripts:$PATH"
```

---

## Docker Images: ALWAYS Pin by Digest

```wdl
runtime {
    docker: "quay.io/biocontainers/liftoff@sha256:63d9a69375519259f155e2f0b0a61b4c95287684f324c7193e2cead7e4ef5894"
    cpu: 32
    memory: "128 GiB"
}
```

**Never use mutable tags** (`latest`, `v1.2`, etc.) — they can resolve to different
images between submission and execution.

**On Perlmutter/Shifter:** Must pre-pull images before submitting:
```bash
shifterimg pull image@sha256:<64-char-hex-digest>
# Verify: output should end with "status: READY"
```
If the digest hasn't been pulled, Shifter returns rc=-1 and the task fails immediately.

### Getting a digest
```bash
docker pull <image>:<tag>
docker inspect --format='{{index .RepoDigests 0}}' <image>:<tag>
# or
docker manifest inspect <image>:<tag> | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['config']['digest'])"
```

---

## Runtime Block

```wdl
runtime {
    docker: "image@sha256:..."
    cpu: 4
    memory: "16 GiB"   # or "16 GB"
}
```

Cromwell/JAWS uses `memory` and `cpu` to request SLURM resources.
If not specified, defaults are small (1 CPU, 2 GB). Always specify for non-trivial tasks.

Supported runtime fields:
| Field | Notes |
|---|---|
| `docker` | Required. Full SHA256 digest always. |
| `cpu` | Thread count. Perlmutter full node = 256 threads. |
| `memory` | e.g. `"16 GiB"` or `"16 GB"`. Default: 2G. |
| `runtime_minutes` | Required. SLURM wall time. Perlmutter max: **2,865 min** (~47.75 h). |
| `gpu` | Optional boolean. Perlmutter only — requests 1 GPU node. |

**Perlmutter node specs:** 3,072 nodes, 492 GB usable RAM, 256 threads, max 2,865 min runtime.

**Docker/ENTRYPOINT:** Cromwell generates its own bash script and runs it directly. The image ENTRYPOINT is bypassed. Bash must be present in your image.

---

## Handling Directories (WDL has no Directory type)

WDL passes `File` objects, not directories. Standard pattern: **tar the directory**.

```wdl
# Task that produces a directory: tar it
command <<<
    mkdir output_dir
    # ... populate output_dir ...
    tar cf output.tar output_dir
>>>
output {
    File result_tar = "output.tar"
}

# Downstream task: untar it
command <<<
    tar xf ~{input_tar}
    # output_dir/ is now available
>>>
```

---

## Refdata — Shared Reference Data

JAWS provides centralized shared reference data mounted **inside containers** at `/refdata/<group>/`.

**Always declare refdata paths as `String`, never `File`:**
```wdl
# CORRECT — accessed inside container at the given path
String ref_db = "/refdata/phytzm/hmm"

# WRONG — triggers Cromwell staging, which fails because /refdata only
# exists inside the container, not on the submission host
File ref_db = "/refdata/phytzm/hmm"
```

**Refdata paths by project (host filesystem → container mount):**
| Project | Host path | Container mount |
|---|---|---|
| JGI/phytzm | `/global/dna/shared/databases/jaws/refdata/<group>/` | `/refdata/<group>/` |
| NMDC | `/global/cfs/cdirs/m3408/refdata/<group>/` | `/refdata/<group>/` |

**Adding data to refdata** (sync takes ~20 min):
```bash
# SSH to a DTN node (compute nodes have read-only access to refdata)
ssh dtn01.nersc.gov
mkdir -p /global/dna/shared/databases/jaws/refdata/<group>/mydata
chmod 440 /global/dna/shared/databases/jaws/refdata/<group>/mydata/*
# Create manifest listing new files (one absolute path per line):
echo "/global/dna/shared/databases/jaws/refdata/<group>/mydata/file.fa" \
    >> /global/dna/shared/databases/jaws/refdata/<group>/<username>_changes.txt
# Background daemon checks every 20 min and submits Globus transfer
```
Deletions propagate only during monthly full sync.

---

## Passing Files vs. Strings

- **`File` input**: JAWS stages the file to the execution environment. Use for actual data.
- **`String` input**: Just a string value. Use for paths on shared filesystems (CFS, etc.)
  that tasks can access directly — but be aware this bypasses staging.

```wdl
# File input — JAWS copies it
input { File genome_fasta }

# String input — path on CFS, task accesses directly
input { String tarball_dir }
# Then in task: File derived = "${tarball_dir}/" + some_name + ".tgz"
```

Constructing a `File` output from a String path (as in `getJbname` above) works only
if the file exists and is accessible to the execution node.

---

## Optional Inputs and Conditional Tasks

```wdl
workflow MyWorkflow {
    input {
        File? optional_file    # ? = optional
    }

    if (defined(optional_file)) {
        call myTask { input: f = select_first([optional_file]) }
    }

    # Carry forward whichever branch ran:
    File result = select_first([myTask.output_file, some_default])
}
```

For conditional arrays (collecting optional task outputs):
```wdl
Array[File] optional_tars = if defined(optional_file) then [select_first([myTask.track_tar])] else []
Array[File] all_tars = flatten([required_tars, optional_tars])
```

---

## Sub-workflows and Imports

```wdl
import "task/util.wdl" as util
import "subworkflow.wdl" as sub

call util.myTask { input: ... }
call sub.myWorkflow { input: ... }
```

Use **relative paths** for imports. JAWS auto-generates a zip of sub-workflows from
the WDL's directory. Make sure all imported WDL files are co-located.

**CRITICAL: Submit from the WDL's directory.** JAWS resolves relative imports from the
**current working directory**, not from the WDL file's location. If you run
`jaws submit` from a parent directory with `jaws/hmmsearch.wdl`, imports like
`"tasks/foo.wdl"` resolve to `./tasks/foo.wdl` (the parent's tasks), not
`./jaws/tasks/foo.wdl`. The error looks like:
```
Subworkflows not found. Error: Required workflow input 'Workflow.Task.old_input' not specified
```
Fix: `cd` to the WDL's directory before submitting, then use just the filename:
```bash
cd /path/to/jaws && jaws submit hmmsearch_jaws.wdl input.json perlmutter
```

When calling a sub-workflow multiple times with different inputs, use `as`:
```wdl
call sub.GFF2toTrack as proteinAlignments { input: gff2_file = protein_gff }
call sub.GFF2toTrack as rnaExpression    { input: gff2_file = rna_gff }
```

---

## Inline Python in WDL Commands

For simple Python operations without a separate script or Docker:
```wdl
task modifyJson {
    input { File in_json }
    command {
        python3 <<EOF
        import json
        with open("${in_json}") as f:
            data = json.load(f)
        data["key"] = "value"
        with open("out.json", "w") as f:
            json.dump(data, f)
        EOF
    }
    output { File result = "out.json" }
    runtime { docker: "python:3.9-slim@sha256:..." }
}
```

Use `${wdl_var}` (not `~{wdl_var}`) inside heredoc to avoid Python/shell conflicts.

---

## Building a Multi-Pair Submission Script

Pattern from `prepare_multiple_jaws.py`:
```python
import subprocess, json, os, glob, shutil

for pid1, pid2 in pairs:
    workdir = f"workdir/{pid1}_{pid2}"
    os.makedirs(workdir, exist_ok=True)

    # Generate input JSON(s) for this pair
    generate_input_json(pid1, pid2, workdir)

    jsonfiles = glob.glob(f"{workdir}/*.json")
    os.chdir(workdir)
    wdl = os.path.abspath("pipeline.wdl")  # absolute path

    for jf in jsonfiles:
        cmd = f"jaws submit --team phytzm --tag {pid1}_{pid2} {wdl} {jf} perlmutter"
        result = subprocess.run(cmd.split(), stdout=subprocess.PIPE)
        run_id = json.loads(result.stdout)["run_id"]
        # save run_id for later status checking

    os.chdir(root_dir)
```

Key: `cd` to the working dir so relative paths in input JSON resolve correctly.
Use absolute path for the WDL file.

---

## Debugging Failed Runs

```bash
jaws tasks <run_id>              # Find which task failed and its return_code
jaws status <run_id>             # Get cromwell_run_id and workflow_root path
```

Task stderr/stdout location:
```
<workflow_root>/call-<TaskName>/execution/stderr
<workflow_root>/call-<TaskName>/execution/stdout
```

For sub-workflow tasks:
```
<workflow_root>/call-<SubName>/<SubWorkflowName>/<uuid>/call-<TaskName>/execution/stderr
```

Common failures:
| rc | Cause | Fix |
|---|---|---|
| `rc=2` | Command not found, file not found, or script error | Check stderr |
| `rc=-1` | Shifter failed to find Docker image (not pre-pulled) | `shifterimg pull image@sha256:...` |
| `rc=79` | Task terminated by Cromwell (filesystem instability, output detection failure) | `jaws resubmit` — JAWS auto-retries rc=79 |
| `rc=127` | Symbol errors from Alpine musl vs glibc (Shifter mpich injection) | Switch to Debian-based image |
| `rc=137` | Memory exceeded | Increase `memory` in runtime block |
| Missing RC file | HTCondor scheduler interruption | `jaws resubmit` |

**Other gotchas:**
- Special characters in filenames (backticks, semicolons) cause job failures — avoid them.
- Relative paths in `inputs.json` resolve relative to the **inputs.json file location**, not the submission directory.

---

## Call Caching

Cromwell caches task calls by input hash. If inputs haven't changed, cached results
are reused. This is ON by default in JAWS.

- Use `--no-cache` to force re-execution of all tasks
- Use `jaws resubmit` to resubmit a failed run — completed tasks are cached
- Useful for iterating on a pipeline: fix the failing task, resubmit, cached tasks skip

**Input file caching:** JAWS caches staged input files for ~14 days, reusing them via
hard-links across runs. Identical files (same path + content) are not re-transferred.
If you modify a file while keeping the same filename, use `jaws submit --overwrite-inputs`
to force re-staging (may affect other runs sharing the cached file).

**String inputs and call caching:** `String` inputs don't hash consistently across
execution locations — a string path to the same file may differ between runs, busting
the cache. Use `File` inputs when cache hits matter for large/slow tasks.

---

## Practical Workflow Template

```wdl
version 1.0

workflow MyPipeline {
    input {
        File input_file
        String output_prefix
        Int n_cpu = 8
    }

    call step1 {
        input: in = input_file, cpu = n_cpu
    }

    call step2 {
        input: step1_result = step1.result, prefix = output_prefix
    }

    output {
        File final = step2.final
    }
}

task step1 {
    input {
        File in
        Int cpu
    }
    command <<<
        my_tool ~{in} > result.txt
    >>>
    output {
        File result = "result.txt"
    }
    runtime {
        docker: "myimage@sha256:..."
        cpu: cpu
        memory: "16 GiB"
    }
}

task step2 {
    input {
        File step1_result
        String prefix
    }
    command <<<
        process ~{step1_result} ~{prefix}.out
    >>>
    output {
        File final = "~{prefix}.out"
    }
    runtime {
        docker: "myimage@sha256:..."
        cpu: 1
        memory: "4 GiB"
    }
}
```

---

## Perlmutter-Specific Gotchas

### Float inputs crash JAWS submission
JAWS's `_gather_absolute_paths` function cannot handle `Float`-typed workflow inputs —
it throws `cannot perform op=_gather_absolute_paths on object of type <class 'float'>`.

**Workaround:** Declare numeric parameters that aren't `Int` as `String` in the WDL.
The value passes through to command-line arguments unchanged.

```wdl
# BAD — crashes jaws submit
input { Float max_evalue = 1e-10 }

# GOOD
input { String max_evalue }
# In input JSON: "workflow.max_evalue": "1e-10"
```

### Scientific notation rejected in WDL default values
The WDL parser rejects scientific notation (e.g. `1e-10`) in default value expressions.
Use decimal form or omit the default and require it in the input JSON.

```wdl
# BAD — parse error at submission
Float max_evalue = 1e-10

# GOOD — decimal form (or just omit the default)
Float max_evalue = 0.0000000001
```

### `runtime_minutes` is required for all tasks
JAWS needs `runtime_minutes` in every task runtime block to set the SLURM wall time.
Without it, JAWS emits warnings and may use a very short default. Always specify it:

```wdl
runtime {
    docker: "image@sha256:..."
    cpu: 4
    memory: "16 GiB"
    runtime_minutes: 60   # required — SLURM wall time in minutes
}
```

Rough guidelines: lightweight I/O tasks: 5–15 min; MSA/hmmbuild: 120 min;
full hmmsearch node: 360 min. Be generous — JAWS will kill the job if it exceeds this.

---

### shifterimg pull: user-namespace images must be pulled by tag, not digest

For **library images** (e.g. `postgres`), pulling by digest works:
```bash
shifterimg pull postgres@sha256:<64-hex>
```

For **user-namespace images** (e.g. `docker.io/yourusername/myimage`), pulling by digest
**silently fails or produces a broken image** because the manifest list digest differs from
the platform manifest digest. Pull by tag instead:
```bash
shifterimg pull docker.io/yourusername/myimage:latest
shifterimg images | grep myimage   # verify status = READY
```
Then use the full digest in WDL (from `docker inspect` or `podman inspect` after push).
The digest in WDL tells Cromwell which image to pass to Shifter; Shifter matches it
against what was pulled by tag.

---

### Shell wrapper scripts that use `dirname "$0"` break when called via PATH

If a wrapper script does:
```bash
SCRIPT_DIR=$(dirname "$0")
python3 "$SCRIPT_DIR/helper.py" ...
```
and is called via PATH (as happens in Docker containers), `dirname "$0"` returns `.` (cwd),
not the script's install directory. The script then fails to find sibling scripts.

**Fix:** Call the Python script directly instead of through the shell wrapper, or rewrite
the wrapper to use `$(dirname "$(readlink -f "$0")")`.

---

### Large `File` inputs: caching and upload cost

JAWS caches staged `File` inputs for ~14 days via hard-links. The first submission
uploads the file; subsequent submissions with the same file reuse the cache at no cost.
A 5 GB bigprotfile costs ~8 seconds to upload once, then is free on re-runs.

- `jaws resubmit <run_id>` always reuses the original staged inputs (no upload at all).
- If you change a file's content without renaming it, use `--overwrite-inputs` on submit.
- For files on shared filesystems accessible from compute nodes, `String` inputs bypass
  staging entirely — but lose call-cache consistency (see Call Caching section).

---

### `$JAWS_SITE` — site-specific logic in task commands

The env var `$JAWS_SITE` is automatically set during task execution (uppercase):
`PERLMUTTER`, `DORI`, etc. Use it for site-specific branches in the command block:

```bash
if [ "$JAWS_SITE" == "PERLMUTTER" ]; then
    # Perlmutter-specific path or tool
fi
```

---

### Perlmutter memory cap: 480 GB max
Perlmutter CPU nodes have 512 GB RAM but only ~492 GB is available after OS overhead.
JAWS enforces this as a hard cap and rejects the submission if any task exceeds it.

- Request at most **480 GB** (or `480 GiB` ≈ 515 GB — use GB units to be safe)
- JAWS reports the limit in GB, not GiB

---

## Checklist Before Submitting

1. `source ~/jaws-prod.sh`
2. **`cd` to the WDL's directory** before submitting (imports resolve from cwd)
3. `jaws validate pipeline.wdl`
4. Verify all Docker images are pre-pulled on Perlmutter:
   - Library images: `shifterimg pull image@sha256:<64-hex>`
   - User images: `shifterimg pull image:tag` (digest pull fails for user-namespace images)
5. Verify input JSON has `WorkflowName.input_name` key format
6. All scripts used by tasks are baked into Docker images (not referenced from filesystem)
7. Avoid shell wrapper scripts that use `dirname "$0"` — call Python scripts directly
8. All task runtime blocks have `runtime_minutes` set
9. Directories passed as tarballs between tasks
10. No mutable Docker tags anywhere in WDL
