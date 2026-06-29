# deploy_config_metadata & njphytozome.json deployment guide

How Phytozome deployments work: which proteomes are in a release, generating
`njphytozome.json` (the frontend clade/organism tree), pushing it, and switching
the live deployment via `current_release`.

Repo: **`~/git/deploy_config_metadata/`** (separate from `~/git/compgen/`; this repo has the authoritative deploy scripts).
DB: **`deploy_config_metadata` on `plant-db-5.jgi.lbl.gov`**. Credentials in `~/.confFile` `[deploy_config_metadata]` (write) — read them via `ConfigReader`/`configparser`, never inline. For CLI use the `--defaults-group-suffix` group in `~/.my.cnf`. Never put a password in a command, script, or guide.

## Key scripts (bin/)

- `create_new_deployment.py --source-deploy-id <id> --deploy-tag <tag>` — clone an existing deployment to a new deploy_id + tag (defaults source to current production). `--dry-run` supported. Prompts `yes/no` (pipe `echo yes |`).
- `add_proteomes_to_deployment.py --deploy-id <id> --input <tsv>` — add proteomes; TSV is `proteome_id<TAB>clade_name`, one per line. Adds the proteome to that clade and every ancestor up to root.
- `remove_proteomes_from_deployment.py` — remove proteomes.
- `inspect_deployment.py` — query deployment state.
- `update_njphytozome.sh <deploy_tag>` — generate `njphytozome.json` from a deploy tag.
- **No script sets `current_release`** — that's direct SQL.

## Generating njphytozome.json

```bash
bash ~/git/deploy_config_metadata/bin/update_njphytozome.sh <deploy_tag>
```
1. `reportClientSideConfig.pl --tag <tag> -o nj.json -c node_cladecuts.cfg`
2. `jq --sort-keys` normalize (2-space indent)
3. **Injects `additionalClusterNodes` from the EXISTING njphytozome.json** (the pan-genome cluster nodes — SBPAN/BRAPAN/etc. — are NOT in the deploy DB and must be preserved). Run on whichever branch you intend to commit to, so it preserves that branch's cluster nodes.
4. Copies result to `~/git/zome-clientside/config/njphytozome.json`. Does NOT commit/push — review the diff first.

`dataPolicy` (restricted/unrestricted) in the generated JSON is **sourced from CHADO `data_restriction_policy`** at generation time — see `~/.claude/restriction-guide.md`.

## Branches & pushing (zome-clientside)

- **dev = `trunk`**, **prod = `production-14.0`**. `production-14.0` is DIRECTLY edited, not merged from trunk.
- To push trunk's njphytozome.json to prod, either regenerate on the production-14.0 branch from the prod deploy, OR cherry-pick the file:
  ```bash
  cd ~/git/zome-clientside
  git fetch origin && git checkout production-14.0 && git pull --ff-only origin production-14.0
  git checkout trunk -- config/njphytozome.json   # only if trunk's content is what prod should have
  git commit -m "Add <PIDs> to production"         # short, no Co-Authored-By
  git push origin production-14.0
  ```
- Commit messages: short, e.g. `Add 962, 1053, 1054 to production` / `dev: add 962, 988, 1053, 1054`. No co-author line.

## current_release (selecting the active deployment) — direct SQL

```sql
UPDATE current_release SET deploy_id = <new_deploy_id>, date = NOW() WHERE environment = 4;  -- prod
SELECT * FROM current_release;
```
Environment values: **1=zome, 2=dev, 3=staging, 4=production, 5=local.** Use `--defaults-group-suffix=_njp_content_write` (creds in `~/.my.cnf`) to avoid passwords on the cmdline.

## Typical new-release workflow

1. Clone the right source deploy → `create_new_deployment.py --source-deploy-id <id> --deploy-tag phytozome-next_YYYYMMDD[_desc]`
2. Build the proteome→clade TSV; `add_proteomes_to_deployment.py --deploy-id <new> --input <tsv>`
3. `update_njphytozome.sh <tag>` on the target branch (trunk for dev, production-14.0 for prod)
4. Review `git diff config/njphytozome.json` — expect only the added proteomes + clade `parentId` renumbering (fresh clade ids → expected diff noise)
5. Commit + push the branch
6. `UPDATE current_release` for that environment (2=dev, 4=prod)

## CRITICAL: verify the source deploy_id before cloning

`current_release.environment=4` is **frequently stale** — njphytozome.json changes get file-pushed to production-14.0 without a matching `UPDATE current_release`, so the pointer can lag the live state by months/years.

Confirm what's actually live before cloning "current production":
```bash
curl -sS https://phytozome-next.jgi.doe.gov/info/<any_pid> | tail -10
# trailing HTML comment → deployTag, branch, commitHash
```
Match `deployTag` to `SELECT deploy_id FROM deploy_version WHERE deploy_tag='<live_tag>'`. If it ≠ `current_release` env=4, clone from the **live** deploy (`--source-deploy-id <that_id>`), and fix the pointer (`UPDATE current_release SET deploy_id=<live_id> WHERE environment=4`).

**Symptom of a stale baseline:** `update_njphytozome.sh` produces a diff with hundreds of *deletions* of proteomes that ARE live (they're in the live file but not the cloned deploy's `deploy_release`). Abort and re-clone — pushing that JSON silently un-adds live proteomes.

## Lessons / gotchas

- **No `delete_deployment.py`.** A wrong-baseline/wrong-tag deploy can be left orphaned (harmless — nothing in `current_release` points to it) or manually DELETEd from `deploy_release, release_metadata, deploy_metadata, deploy_node, deploy_clade, deploy_version` (ask the user first).
- `deploy_version.deploy_tag` is UNIQUE — a botched create blocks tag reuse; append a suffix (`..._boechera`).
- `add_proteomes` TSV clade name must match an existing `deploy_clade.name` for the source deploy. Find the most-specific clade by checking which clade contains a taxonomically-related, already-deployed proteome: `SELECT name FROM deploy_clade WHERE deploy_id=<id> AND proteomes RLIKE '(^|,)<ref_pid>(,|$)'` (smallest such clade = most specific).
- After deploy, the running frontend only updates when the **server/container deploy** runs (the git push + current_release switch don't redeploy the static build). The SPA shell's `deployTag` may be rendered dynamically from current_release while the served `njphytozome.json` asset is still the old build until a rebuild.

## In-repo docs
`DEPLOYMENT_TOOLS_SUMMARY.md` (canonical current_release SQL), `UPDATED_USAGE_GUIDE.md`, `QUICK_START.md`, `ADD_PROTEOMES_README.md`, `CREATE_DEPLOYMENT_README.md`, `CHANGES_SUMMARY.md`.
