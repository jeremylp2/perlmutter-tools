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

# Get the digest (manifest v2 hash — this is the authoritative SHA256 to use everywhere):
curl -s \
    "https://registry-1.docker.io/v2/jlphillipslbl/hmmsearch-pipeline/manifests/latest" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Authorization: Bearer $(curl -s \
        'https://auth.docker.io/token?service=registry.docker.io&scope=repository:jlphillipslbl/hmmsearch-pipeline:pull' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')" \
    | python3 -c "
import hashlib, sys
body = sys.stdin.buffer.read()
print('sha256:' + hashlib.sha256(body).hexdigest())
"

# Pull into Shifter using the full SHA256 digest — ALWAYS, no exceptions:
shifterimg pull docker.io/jlphillipslbl/hmmsearch-pipeline@sha256:<64-hex-digest>
shifterimg images | grep <short-digest>   # must show READY

# Use the same full digest in all WDL docker fields:
#   docker: "docker.io/jlphillipslbl/hmmsearch-pipeline@sha256:<64-hex>"
```

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
