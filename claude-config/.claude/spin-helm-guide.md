# SPIN / Helm / kubectl guide (NERSC SPIN, `dsi` + `plant`)

Self-contained operational guide for deploying and running workloads on **NERSC SPIN** (Rancher-managed
Kubernetes) from a Perlmutter login node. Written to be usable **without any repo** — the manifest
skeletons below are complete and OPA-compliant, so you can deploy with plain `kubectl apply` even if no
Helm charts are available. Everything here is verified against the live `dsi`/`plant` namespaces.

---

## 0. Access setup (one-time per machine)

`helm` and `kubectl` are already on the Perlmutter login-node PATH. You need two things:

**a) A kubeconfig.** Get it from the Rancher UI at <https://rancher2.spin.nersc.gov> → open the cluster
→ "Download KubeConfig" (or "Copy KubeConfig"), and save it as **`~/.kube/development.yaml`**. Its
context/cluster/user are all named `development`; its default namespace is `plant`. Kubeconfigs contain
bearer tokens — never commit or echo their contents.

**b) The Rancher CLI** (only needed for `rancher` commands, NOT for kubectl/helm):
```bash
module load spin/2.0
# Create an API key at https://rancher2.spin.nersc.gov/dashboard/account
#   - scope: "no scope" (important);  expiration: ~1 year
rancher login --token <BEARER_TOKEN> https://rancher2.spin.nersc.gov/v3
# token is cached in ~/.rancher/cli2.json; re-login only when it goes stale
```

For private images there is `registry.nersc.gov` (project namespaces like `m342/...`), but the cluster
can also pull **public registries directly** — verified: `docker.io/*` and `docker.elastic.co/*` pull
with no mirror/config.

---

## 1. ABSOLUTE FIRST STEP — the kubeconfig, every time

**ALWAYS `export KUBECONFIG=~/.kube/development.yaml` before any `kubectl`/`helm` command.** A bare
`kubectl`/`helm` uses the wrong/empty config and silently fails or hits nothing. This is the single
most-forgotten thing. Shell state does NOT persist between separate command invocations, so put it in
the *same* command as the work:

```bash
export KUBECONFIG=~/.kube/development.yaml
kubectl -n dsi get pods
```

Always pass `-n <ns>` explicitly rather than relying on the context default.

---

## 2. Namespaces and RBAC

- **`dsi`** — data-lakehouse / DSI work (e.g. the `pfam-univ` app, a dedicated `pfam-es`
  Elasticsearch, batch build Jobs).
- **`plant`** — the Zome platform (Phytozome etc.): `zome-proxy`, `zome-elasticsearch`, many `zome-*`.
- Access is **namespaced only**. Cluster-scope reads are **forbidden** — `kubectl get nodes`,
  `kubectl top node`, and `get pods --all-namespaces` all return RBAC 403. That is expected, not a
  broken cluster. You cannot read node capacity directly; infer it indirectly (see §7).

---

## 3. Deploying — Helm *or* plain kubectl

If you have Helm charts:
```bash
export KUBECONFIG=~/.kube/development.yaml
helm template <release> <chartdir> -f <chartdir>/values-<env>.yaml --debug   # dry-run FIRST
helm -n <ns> upgrade --install <release> <chartdir> -f <chartdir>/values-<env>.yaml  # idempotent
helm -n <ns> list
helm -n <ns> history <release>
helm -n <ns> rollback <release> <rev>
helm -n <ns> uninstall <release>
```
- One chart serves many deployments via per-environment `values-<env>.yaml` files. **Keep secrets and
  host-specific values OUT of committed files** (gitignore `*.secret`, `values-sandbox.yaml`, etc.).
- `--atomic` auto-rolls-back a failed deploy — use it for production.

**Without charts**, everything below is a complete `kubectl apply -f` manifest. Helm is just a
templating layer over these same objects.

---

## 4. Security context — SPIN OPA / NGF policies (REQUIRED or apply is DENIED)

SPIN enforces OPA/NGF admission policies. A pod spec missing these is **rejected at apply time** (the
error shows in `kubectl apply` output or `kubectl describe`):

- `runAsNonRoot: true` **and** explicit **`runAsUser` + `fsGroup` = your numeric uid** (`id -u`;
  examples here use `57198`). Set them at the pod `securityContext`; also set `runAsUser` on the
  container.
- Container `securityContext`: `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`.
- **hostPath mounts:** CFS (`/global/cfs/cdirs/...`) is allowed **with** the uid/fsGroup above.
  **`/global/homes/...` is BLOCKED (NGF-002)** — never hostPath a home dir; use CFS or a PVC.

---

## 5. Complete copy-paste manifests (OPA-compliant)

Replace `57198` with your `id -u`, `dsi` with your namespace, and image/host/paths as needed.

### 5a. Secrets — NEVER put credentials on the command line

Passwords/tokens in `--from-literal=` land in `ps`/shell history. Use **files**:
```bash
export KUBECONFIG=~/.kube/development.yaml
# generic secret from a key=value file (chmod 600 it; do not commit):
kubectl -n dsi create secret generic myapp-secret --from-env-file=./creds.env \
  --dry-run=client -o yaml | kubectl -n dsi apply -f -
# TLS secret from cert/key files (self-signed is fine for internal):
kubectl -n dsi create secret tls myapp-tls --cert=tls.crt --key=tls.key
# nginx basic-auth secret — key MUST be named 'auth', value is an htpasswd file:
#   generate the htpasswd file WITHOUT the password on the CLI (interactive prompt):
htpasswd -B -c ./htpasswd myuser        # prompts for the password; never pass it inline
kubectl -n dsi create secret generic myapp-basicauth --from-file=auth=./htpasswd
```
Reference secrets from pods via `valueFrom.secretKeyRef` (never inline the value). A server that reads
a secret **per request** picks up a rotated secret with just `kubectl apply` — no restart. Force a
restart when needed: `kubectl -n dsi rollout restart deploy/<name>`.

### 5b. PVC (managed storage; StorageClass `nfs-client-vast`)
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: myapp-data, namespace: dsi }
spec:
  accessModes: ["ReadWriteMany"]        # NFS supports RWX (multi-pod); RWO also fine
  storageClassName: nfs-client-vast
  resources: { requests: { storage: 100Gi } }
```
See §6 for the important nfs-client-vast quirks (the size is nominal, not a hard quota).

### 5c. Deployment + Service
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: myapp, namespace: dsi, labels: { app: myapp } }
spec:
  replicas: 1
  selector: { matchLabels: { app: myapp } }
  template:
    metadata: { labels: { app: myapp } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 57198, runAsGroup: 57198, fsGroup: 57198 }
      containers:
      - name: myapp
        image: docker.io/library/node:20-slim      # prefer @sha256:<digest> for durable workloads
        ports: [{ containerPort: 8096 }]
        env:
        - { name: PORT, value: "8096" }
        - name: SECRET_TOKEN
          valueFrom: { secretKeyRef: { name: myapp-secret, key: token } }
        resources: { requests: { cpu: "1", memory: 1Gi }, limits: { memory: 2Gi } }
        readinessProbe: { httpGet: { path: /, port: 8096 }, initialDelaySeconds: 10 }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 57198
          capabilities: { drop: ["ALL"] }
        volumeMounts: [{ name: data, mountPath: /data }]
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: myapp-data }
        # OR a CFS hostPath (allowed; /global/homes is NOT):
        # hostPath: { path: /global/cfs/cdirs/<project>/<dir>, type: Directory }
---
apiVersion: v1
kind: Service
metadata: { name: myapp, namespace: dsi }
spec:
  selector: { app: myapp }
  ports: [{ port: 8096, targetPort: 8096 }]   # ClusterIP (in-cluster) by default
```

### 5d. Ingress (TLS + optional basic auth)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: dsi
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # optional password gate (see 5a for the secret):
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: myapp-basicauth
    nginx.ingress.kubernetes.io/auth-realm: "Restricted"
spec:
  ingressClassName: nginx
  tls: [{ hosts: ["<your-host>"], secretName: myapp-tls }]
  rules:
  - host: "<your-host>"
    http:
      paths:
      - { path: /, pathType: Prefix, backend: { service: { name: myapp, port: { number: 8096 } } } }
```
SPIN assigns ingress hostnames by its own convention — **don't invent one**; copy the pattern from an
existing ingress in your namespace: `kubectl -n dsi get ingress -o wide`.

### 5e. Long-running batch work → a Kubernetes Job (session-independent)
For any multi-hour load/build, DO NOT run it foreground or tied to your shell/ssh/Claude session — run
it as a **Job** so it survives login-node death:
```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: mybuild, namespace: dsi, labels: { app: mybuild } }
spec:
  backoffLimit: 20
  ttlSecondsAfterFinished: 1209600            # self-clean after finish
  template:
    metadata: { labels: { app: mybuild } }
    spec:
      restartPolicy: OnFailure
      securityContext: { runAsNonRoot: true, runAsUser: 57198, runAsGroup: 57198, fsGroup: 57198 }
      containers:
      - name: build
        image: docker.io/library/python:3.12-slim
        command: ["/bin/sh","-c"]
        args: ["set -e; export HOME=/build; pip install --target=/build/.pydeps --quiet <deps>; \
                PYTHONPATH=/build/.pydeps python3 /build/run.py"]
        env:
        - { name: WORKERS, value: "14" }
        - name: S3_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: mybuild-s3, key: S3_SECRET_ACCESS_KEY } }
        resources: { requests: { cpu: "4", memory: 4Gi }, limits: { memory: 8Gi } }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 57198
          capabilities: { drop: ["ALL"] }
        volumeMounts: [{ name: build, mountPath: /build }]
      volumes:
      - name: build
        hostPath: { path: /global/cfs/cdirs/<project>/<dir>, type: Directory }  # code+checkpoint on CFS
```
**Make the Job resumable:** have `run.py` append completed items to a checkpoint file on the CFS mount
and skip them on start, and use **deterministic record IDs** so a re-processed in-flight item is an
idempotent upsert (no dupes, no loss). Then a restart is always safe.

**Changing a running Job** (its pod template is immutable — e.g. to bump `WORKERS`): delete and
re-apply. The CFS checkpoint persists, so it resumes:
```bash
export KUBECONFIG=~/.kube/development.yaml
kubectl -n dsi delete job mybuild --cascade=foreground --wait=true   # wait for pod to fully die
kubectl -n dsi get pods -l app=mybuild                               # MUST be empty before relaunch
kubectl -n dsi apply -f mybuild-job.yaml                             # WORKERS changed
```
Two writers to the same index/table/files = corruption, so **confirm the old pod is gone first.** When
recreating from a live object (`kubectl get job <name> -o yaml`), strip the fields the API adds:
`status`, `metadata.{creationTimestamp,resourceVersion,uid,generation}`, the auto-generated
`spec.selector` + `template.metadata.labels.controller-uid`/`job-name`, and the SPIN-injected
`nersc.gov/*` annotations (they're re-added by admission).

---

## 6. Storage — `nfs-client-vast` quirks (read before sizing a PVC)

Verified empirically, and counter-intuitive:

- **The PVC size is NOT a hard quota.** The provisioner does not enforce `spec.resources.requests`,
  and `status.capacity` can stay **stale** (e.g. still reads `50Gi` long after a resize to `1Ti`). A
  pod can and does write far past its nominal PVC size.
- **Ground truth is `df` inside the pod**, not the PVC object:
  `kubectl -n dsi exec <pod> -- df -h <mountpath>` — it shows the whole shared VAST filesystem
  (observed ~887 TB size, ~819 TB free). So don't panic at a small `status.capacity`; check `df`.
- Still request a sensible size for intent/documentation. NFS supports `ReadWriteMany` (multi-pod).

---

## 7. Observing + debugging

```bash
export KUBECONFIG=~/.kube/development.yaml
kubectl -n dsi get pods -o wide
kubectl -n dsi logs -l app=<label> --tail=20        # by label — survives pod-name churn
kubectl -n dsi logs -f deploy/<name>
kubectl -n dsi exec deploy/<name> -- <cmd>          # e.g. df -h, curl localhost:PORT/...
kubectl -n dsi top pod -l app=<label>               # live CPU/mem  (top NODE is FORBIDDEN)
kubectl -n dsi describe pod <pod>                    # events: scheduling, OPA denial, OOMKilled
kubectl -n dsi get pvc,secret,svc,ingress
```
- **Reach a ClusterIP service from the login node:** `kubectl -n dsi port-forward svc/<svc> 9201:9200`
  then hit `localhost:9201`. Or one-shot inside a pod: `kubectl exec deploy/<x> -- curl -s localhost:PORT/...`.
  **Minimal images often lack `curl` AND `wget`** — check first (`which curl`); an ES image here had
  curl but not wget, a node image had neither. Don't trust a "0 results" that's really "command not found".
- **CPU headroom:** a container with a memory `limit` but **no cpu `limit` is uncapped on CPU** — it
  bursts to whatever the node has free (the cpu *request* only affects scheduling). Since you can't read
  node stats, judge saturation from the app itself, not the node.

---

## 8. Elasticsearch on SPIN (operational lessons — apply to any bulk-load workload)

Running a dedicated ES (`docker.elastic.co/elasticsearch/elasticsearch:9.x`, single-node,
`discovery.type=single-node`, `xpack.security.enabled=false`, `node.store.allow_mmap=false` +
`index.store.type=niofs` to avoid page-cache OOM in a cgroup-limited pod) taught several things that
generalize to any high-throughput ingest:

- **ES has no "load a file" fast path.** Whether docs come from an on-disk NDJSON dump or a live stream,
  ingestion is the **`_bulk` HTTP API in batches** either way. So "dump to disk first" does NOT speed up
  indexing — it just adds a write+read pass. Stream straight into `_bulk`.
- **Memory is bounded by batch size, not dataset size.** A streaming loader that builds ~5k-doc NDJSON
  batches, POSTs, and frees them uses a few hundred MB regardless of whether it's loading 40M or 780M
  docs. "In memory" ≠ "whole dataset in RAM".
- **The real throughput knob is feeder concurrency, not ES.** ES sizes its `write` thread pool to
  `allocated_processors` (e.g. 16). If your loader only sends 6 concurrent bulk requests, only 6 write
  threads are active and ES looks "busy" at low CPU. The saturation signal is the write pool:
  `kubectl exec deploy/pfam-es -- curl -s 'localhost:9200/_cat/thread_pool/write?v&h=active,queue,rejected'`
  — `active < pool size` with `queue=0, rejected=0` means **ES is under-fed**; raise loader workers.
  Raising 6→14 here took ES from ~4.7→~11.3 cores and lifted throughput ~1.3× (single-shard indexing
  hits diminishing returns as merges compete). `rejected>0` means back off (429s).
- A **single shard still indexes multi-threaded** (Lucene `IndexWriter` accepts concurrent adds), so you
  don't need many shards to use many cores. But a single shard >~50 GB exceeds ES guidance — shard for
  size/recovery, not for ingest parallelism.
- **Bulk-load settings:** `refresh_interval: -1` and `number_of_replicas: 0` during load; then restore
  refresh, `_refresh`, and `_forcemerge?max_num_segments=1` at the end. During load `_count` reads **0**
  (nothing refreshed) even though the on-disk store is growing — check `_cat/indices?h=store.size` or
  `df`, not `_count`, for progress.

---

## 9. In-container dev with a live watcher (no rebuild per change)

To iterate on a running service without rebuilding/pushing an image each edit: mount the source from a
**CFS hostPath** into the container and run file-watchers. Network filesystems have **no inotify**, so
watchers must **poll**:
- Node/Express: `nodemon --legacy-watch server.js`
- Vite client: `vite build --watch` (polling)

Deploy a separate `-sandbox` release (own values file) so it never touches the production deployment;
gate it behind the basic-auth ingress (§5a/5d) instead of exposing it. Edit files on CFS → the poller
reloads in-place. Confirm a clean reload: `kubectl -n dsi logs deploy/<sandbox> --tail` should show the
watcher restart with no syntax error.

---

## 10. Gotchas checklist

- Forgot `export KUBECONFIG=~/.kube/development.yaml`? That's 90% of "it doesn't work".
- `kubectl get nodes` / `top node` → RBAC 403; expected (namespaced access only).
- PVC `status.capacity` looks tiny → stale; `df` in the pod is the truth (nfs-client-vast, no quota).
- Pod rejected on apply → missing `runAsUser`/`fsGroup`/`drop ALL`, or a `/global/homes` hostPath.
- Job env change "not taking" → Job template is immutable; delete + re-apply (checkpoint resumes).
- ES/loader "slow" at low CPU → under-fed; check the `write` thread pool, add loader concurrency.
- `_count` is 0 mid-load → normal with `refresh_interval:-1`; watch `store.size`/`df` instead.
- `exec ... curl` returns nothing → image may lack curl/wget; verify the tool exists first.
- Long op in foreground / babysat with `sleep` → move to a Job; poll between turns; give any
  >2-minute command an explicit longer timeout so it isn't killed at the 2-min default.
- Credentials on a `kubectl`/`htpasswd` command line → forbidden; use `--from-file`/`--from-env-file`
  and interactive prompts.
