# Podman on Perlmutter — Build Guide

## The core problem
`TMPDIR=/pscratch/sd/p/phillips` by default. Buildah uses `TMPDIR` for its bundle
working directory. Lustre (pscratch) blocks the mount namespace operations buildah
needs (pivot_root, bind mounts), so every `RUN` step fails with:

    error running container: creating directory ".../buildah<PID>/mnt/rootfs": permission denied

## The fix: override TMPDIR for every podman build/push

Use `XDG_RUNTIME_DIR` (`/run/user/$(id -u)`) — a 51 GB tmpfs that supports all
required mount operations. It is NOT /tmp.

```bash
TMPDIR=/run/user/$(id -u) podman build ...
TMPDIR=/run/user/$(id -u) podman push ...
```

**Never use /tmp — it is forbidden on Perlmutter.**

## Login

Docker Hub username is **jlphillipslbl** (email: jlphillips@lbl.gov):

```bash
echo "<password>" | podman login docker.io -u "jlphillips@lbl.gov" --password-stdin
```

## SHA256 digests — ABSOLUTE RULE, NO EXCEPTIONS

**ALWAYS use full SHA256 digests. NEVER use bare tags. This applies to every command,
every file, every context: WDL docker fields, shifterimg pull, scripts, CLI commands.**

- CORRECT: `shifterimg pull docker.io/jlphillipslbl/hmmsearch-pipeline@sha256:<64-hex>`
- WRONG: `shifterimg pull jlphillipslbl/hmmsearch-pipeline:latest` — NEVER
- CORRECT: `docker: "docker.io/image@sha256:<64-hex>"`
- WRONG: `docker: "image:tag"` or `docker: "image:tag@sha256:..."` — NEVER

`@sha256` pulls work correctly on Perlmutter for all images including user-namespace images.

## Full build → push → shifter pull workflow

```bash
# From analysis/hmmsearch/ (build context must be parent of jaws/)
cd /global/u1/p/phillips/git/compgen/analysis/hmmsearch

# Build (tag is only used locally for the push step — never referenced in WDL or scripts)
TMPDIR=/run/user/$(id -u) podman build \
    -t docker.io/jlphillipslbl/hmmsearch-pipeline:latest \
    -f jaws/Dockerfile .

# Push
TMPDIR=/run/user/$(id -u) podman push docker.io/jlphillipslbl/hmmsearch-pipeline:latest

# Get the digest — ALWAYS read the Docker-Content-Digest RESPONSE HEADER (authoritative):
REPO=jlphillipslbl/hmmsearch-pipeline; TAG=latest
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -sD - -o /dev/null "https://registry-1.docker.io/v2/${REPO}/manifests/${TAG}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json" \
    -H "Authorization: Bearer $TOKEN" \
    | grep -i '^docker-content-digest:' | awk '{print $2}' | tr -d '\r'

# Pull into Shifter using the full SHA256 digest — ALWAYS, no exceptions:
shifterimg pull docker.io/jlphillipslbl/hmmsearch-pipeline@sha256:<64-hex-digest>
shifterimg images | grep <short-digest>   # must show READY

# Use the same full digest in all WDL docker fields:
#   docker: "docker.io/jlphillipslbl/hmmsearch-pipeline@sha256:<64-hex>"
```

## DIGEST TRAP — why the header, not a hash of the manifest body

Podman often pushes an **OCI** manifest. If you request the manifest with
`Accept: application/vnd.docker.distribution.manifest.v2+json` and hash the returned body, the
registry may hand back a *converted* manifest whose sha256 is **not a pullable digest**. Symptom:

    shifterimg pull docker.io/<repo>@sha256:<that-hash>   ->  status: FAILURE

…even though the repo is public and the tag exists. The `Docker-Content-Digest` response header
always reports the digest the registry actually stores. (Real case: jbpythonscripts computed
`f111e922…` by body-hash but the real digest was `4a3352dc…`; another image happened to match,
which makes this failure mode look random.)

Sanity check after every push: `shifterimg pull <repo>@<digest>` must reach `status: READY`.

## Rootless build gotcha

`RUN curl … | tar -xj` fails with `Cannot change ownership to uid …: Invalid argument`.
Add `--no-same-owner`: `| tar -xj --no-same-owner`.

## Repository visibility

New Docker Hub repos are private by default. Shifter cannot pull private images.
Make public via API if needed:

```bash
TOKEN=$(curl -s -X POST "https://hub.docker.com/v2/users/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"jlphillips@lbl.gov","password":"<pw>"}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s -X PATCH "https://hub.docker.com/v2/repositories/jlphillipslbl/<repo>/" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"is_private": false}'
```

## Current images (Perlmutter Shifter)

| Image | Full digest | Pulled |
|-------|-------------|--------|
| `docker.io/jlphillipslbl/hmmsearch-pipeline` | `sha256:b00490547d8afe239c9565d0831727670c484c92c42c0c6d612e73f32fe13d65` | 2026-03-09 |
