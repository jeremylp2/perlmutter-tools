---
description: Report current state of the homolog pipeline — cron, active JAWS runs, pipeline_lock, and proteome status distribution
---

Report the current state of the homolog pipeline. Arguments: $ARGUMENTS

Read `~/.claude/homolog-pipeline-guide.md` and `~/.claude/pipeline-lock-guide.md` for context.

## What this does

Gathers read-only status from multiple sources and presents a unified view:

1. **Pipeline lock state**: is someone running the pipeline right now?
2. **Scrontab cron state**: scheduled, running, held?
3. **Active JAWS runs**: what `homologs_*` runs are in progress?
4. **Proteome status distribution**: counts by status in `proteome_progress`
5. **Most recent cron run**: when did the cron last execute successfully?

All read-only. No writes, drops, deletes, or modifications.

## Steps

1. **Pipeline lock** (MySQL `deploy_config_metadata` on plant-db-5):
   ```bash
   # Use config file for credentials (NEVER inline)
   python3 -c "
   import sys; sys.path.insert(0, '/pscratch/sd/p/phillips/inparanoid/pipeline')
   from config import get_mysql_conn
   conn = get_mysql_conn('deploy_config_metadata')
   c = conn.cursor()
   c.execute(\"SELECT IS_USED_LOCK('homolog_pipeline')\")
   holder = c.fetchone()[0]
   if holder:
       c.execute('SHOW PROCESSLIST')
       rows = c.fetchall()
       match = [r for r in rows if r[0] == holder]
       print(f'LOCKED by connection_id {holder}: {match[0] if match else \"(not in processlist)\"}')
   else:
       print('Lock is FREE')
   c.close(); conn.close()
   "
   ```

2. **Scrontab state**:
   ```bash
   scrontab -l | grep -A 5 homolog
   squeue -u $USER -p cron 2>&1 | grep -E 'homolog|cron'
   ```

3. **Active JAWS runs** (tag starts with `homologs_`):
   ```bash
   source ~/jaws-prod.sh && module load python/3.11-24.1.0
   jaws queue 2>/dev/null | python3 -c "
   import json, sys
   runs = json.load(sys.stdin) if sys.stdin.isatty() else []
   for r in runs:
       tag = r.get('tag', '')
       if tag.startswith('homologs_'):
           print(f\"  {r['id']} tag={tag} site={r['compute_site_id']} status={r['status']}/{r.get('result')} submitted={r['submitted']}\")
   "
   ```
   Alternative: use `jaws history --days 2` and filter.

4. **Proteome status distribution** (MySQL):
   ```bash
   python3 -c "
   import sys; sys.path.insert(0, '/pscratch/sd/p/phillips/inparanoid/pipeline')
   from config import get_mysql_conn
   conn = get_mysql_conn('deploy_config_metadata')
   c = conn.cursor()
   for field in ('homolog_blast_compute', 'inparanoid_computes', 'homolog_load_mongo'):
       c.execute(f'SELECT {field}, COUNT(*) FROM proteome_progress GROUP BY {field} ORDER BY {field}')
       print(f'{field}:')
       for status, n in c.fetchall():
           label = {0:'PENDING', 1:'RUNNING', 2:'DONE', -1:'ERROR'}.get(status, str(status))
           print(f'  {label} ({status}): {n}')
   c.close(); conn.close()
   "
   ```

5. **Recent cron runs**:
   ```bash
   ls -lart /pscratch/sd/p/phillips/jaws/homolog_scron-*.out 2>/dev/null | tail -3
   tail -20 /pscratch/sd/p/phillips/jaws/homolog_cron.log 2>/dev/null
   ```

## Output format

Summarize findings with clear headers:

```
=== Pipeline lock ===
Status: [FREE | HELD by login37:pid=12345]

=== Cron state ===
Scheduled: yes (every 6 hours)
Queue state: <squeue info or "not held">

=== Active JAWS runs ===
<list of in-progress homolog runs>

=== Proteome status ===
homolog_blast_compute: DONE=400, RUNNING=2, PENDING=50, ERROR=1
inparanoid_computes:   ...
homolog_load_mongo:    ...

=== Recent cron runs ===
Last successful run: <date>
Last scron output: <file>
```

If any ERROR statuses exist, list which proteomes.
