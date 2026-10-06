# JBPrivate → IGB (zome-igb-2) sync guide

How a deployed private JBrowse browser, and its login, reach IGB. Verified 2026-10-01.

## Where private browsers are served
- Host zome-igb-2 = 128.3.96.51 (k3s). Kubeconfig `~/.kube/zome-igb-2.yaml`, namespace `igb-dev`
  (igb-prod has no deployments). Deployment/Service `zome-jbprivate` (Apache 2.2, :8082).
- hostPath mounts in the pod:
  - `/usr/local/apache2/html/jbrowse/genomes` ← host `/plant/share/jbrowse/private`
  - `/global/cfs/cdirs/wfs_plnt/zome/project/jbrowse/htaccess` ← host `/plant/share/jbrowse/htaccess`
    (every browser `.htaccess` has `AuthUserFile .../htaccess/htpasswords`; Apache reads it per request, no restart)
- Public URL (through Cloudflare): `https://phytozome-next.jgi.doe.gov/jbprivate/genomes/<browser>/trackList.json`
  → anonymous 401 `Basic realm="Phytozome Private Server"`. Direct 128.3.96.51:443 from Perlmutter times out.
- Authoritative htpasswords: `/global/dna/projectdirs/plant/phytozome/htaccess/htpasswords` (dna).
  `/global/cfs/cdirs/wfs_plnt/zome/project/jbrowse/htaccess/htpasswords` on Perlmutter CFS is a STALE old copy.

## The push channel (write-only rsync)
- Key `~/.ssh/jbprivate-sync/id_jbprivate_push` (phillips), login user `svc-plant@lbl.gov`.
  Authorized in `/home/svc-plant__lbl.gov/.ssh/authorized_keys` on zome-igb-2 with
  `from="128.55.0.0/16",command="/usr/local/bin/jbprivate-rsync-recv",restrict`.
- Wrapper `/usr/local/bin/jbprivate-rsync-recv` allows only `rsync --server`, no `--sender` (no pulls),
  rejects `..`, and the target must be under `/plant/share/jbrowse/private` OR exactly
  `/plant/share/jbrowse/htaccess/htpasswords` (the second rule was added by the user as root, 2026-10-01).
- No scp/sftp/shell through this key. Can't delete on IGB; removal on IGB needs root on zome-igb-2 (user only;
  Claude has no shell there).
- rsync flags (receiver is non-root, so not `-a`): `-rlt --partial --no-perms --no-owner --no-group --chmod=D755,F644`
  + excludes; rc 23/24 = partial, tolerated.
- `compute_farm/jbrowse/JBP/igb-key-setup.md` (compgen master) documents per-user key setup. User directive:
  do NOT edit that doc.

## Automatic push at deploy (compgen branch jbprivate-igb-sync, commit 0610e419)
- `deploy_private_jbrowse.py` Step 6 calls `igb_sync.push(...)` after the dna deploy: under the lock it
  rsyncs htpasswords, then the browser dir, then verifies login (anonymous 401 AND user 200, 6 tries x 10 s,
  cache-buster query). Any failure → exit 1. No flags needed (`--no-igb` exists to skip).
- Standalone: `igb_sync.py <dna browser dir> -u USER --password-file FILE` (password never on command line).
- Run ONLY with `module load python/3.13-26.8.1 && python3 ...` in ONE bash call (user directive).
  paramiko must be `pip install --user`ed per NERSC python build (user-sites are per build:
  `~/.local/perlmutter/python-3.13/<build>/`); a new default build starts empty (same thing broke pymysql).
- stdlib `crypt` is gone in 3.13; the script uses an in-file hashlib SHA-512-crypt, identical output
  (508 cases + glibc vector). User directive: keep paramiko; no openssl/system-call replacements.

## Cross-node lock (shared with the sweep)
- `flock` on CFS is NOT honored across login nodes (tested login11 vs login24). Use atomic mkdir.
- Lock dir `/global/cfs/cdirs/plantbox/phytozome/jbprivate-igb-sync.lock`, with an `owner` file
  (host/pid/user/time/prog). Deploy waits up to 4 h; the sweep skips the run if the lock is held.
- Stale lock: read `owner`, confirm that process is gone on that host, and only then remove it (ask the user first).

## Scheduled sweep
- `~/jbprivate-sync/push_jbprivate.sh` (outside git), scron every 4 h (+ `--full` Sun 03:00), whole tree
  dna jbprivate/ → IGB private/. ~1.5–2 h per run; ends `partial=1` routinely (receiver permission-denied files
  in Stexanusvar_Basel18_female_v1_1). Log `~/jbprivate-sync/sync.log`.

## Traps
- `deploy_private_jbrowse.py --json <JAWS outputs.json>`: `JBPrivate.final_tar` is RELATIVE
  (`./call-coverAndZip/execution/<name>.tar`); the cp runs via `ssh dtn01`, whose cwd is the remote HOME, so it fails
  AFTER htpasswords was already updated. Use `--tarball <absolute path>` (or an absolute final_tar).
- Production JBPrivate runs on dori from szaman's checkout `/global/cfs/projectdirs/plantbox/szaman/gitlab/compgen`;
  recent deploys are by suz11001.
- Tests: never reuse an existing browser name/user ("don't overwrite the old").

## Verify a push
```bash
export KUBECONFIG=~/.kube/zome-igb-2.yaml
POD=$(kubectl -n igb-dev get pods -l app=zome-jbprivate -o name | head -1)
kubectl -n igb-dev exec $POD -- md5sum /global/cfs/cdirs/wfs_plnt/zome/project/jbrowse/htaccess/htpasswords
md5sum /global/dna/projectdirs/plant/phytozome/htaccess/htpasswords      # must match
kubectl -n igb-dev exec $POD -- ls /usr/local/apache2/html/jbrowse/genomes/<browser>/
curl -s -o /dev/null -w '%{http_code}\n' "https://phytozome-next.jgi.doe.gov/jbprivate/genomes/<browser>/trackList.json?x=$(date +%s)"  # 401
# user check: use a netrc/config file for credentials, never -u user:pass on the command line
```
