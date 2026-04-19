# Pipeline Lock Guide

Mechanism for enforcing "only one homolog pipeline instance may run at a time" across hosts (Perlmutter, Dori, anywhere). Uses MySQL advisory locks via `GET_LOCK()`.

## Why

The homolog pipeline regenerates defline files, writes to MongoDB collections, and submits JAWS runs. Running two instances simultaneously could:
- Corrupt a defline file by writing from two processes
- Double-submit JAWS runs for the same proteome
- Race on MongoDB collection drops and loads

File locks (flock) don't work cross-host. Database-level named locks do.

## Implementation

`pipeline/config.py` has:

```python
@contextlib.contextmanager
def pipeline_lock(name='homolog_pipeline', heartbeat_interval=60,
                  conf_path=DEFAULT_CONF_FILE):
    ...
```

Usage:

```python
from config import pipeline_lock

def main():
    with pipeline_lock('homolog_pipeline'):
        # pipeline body
```

Currently wrapped around `main()` in:
- `pipeline/wdl/prepare_jaws.py`
- `pipeline/wdl/homolog_cron.py`

## How it works

MySQL's `GET_LOCK(name, timeout)`:
- **Stored** in memory on the mysqld process (server-wide advisory-lock namespace). NOT written to disk. NOT replicated. Not tied to any table.
- **Named** — we use `'homolog_pipeline'`. Different tools could use different names for their own scoping.
- **Session-scoped** — released automatically when the MySQL connection closes, including on process crash.
- **Advisory** — only blocks code that also calls `GET_LOCK()` with the same name. Does NOT block any other queries, DML, or DDL.

The context manager:
1. Opens a dedicated MySQL connection to `deploy_config_metadata` (plant-db-5)
2. Calls `SELECT GET_LOCK('homolog_pipeline', 0)` — timeout=0 means fail-fast
3. Returns 1 → OK, hold connection open
4. Returns 0 → another instance has it → raise RuntimeError with clear message
5. Starts a daemon heartbeat thread that runs `SELECT 1` every 60s to prevent MySQL's `wait_timeout` from closing the connection during long-running pipelines (6+ hours)
6. On exit: stop heartbeat, `SELECT RELEASE_LOCK(...)`, close connection

## What gets locked

**Nothing in any data table.** `GET_LOCK` is purely advisory — a named flag on mysqld. Other queries against any table (including `proteome_progress`) run unimpeded.

## Failure modes

| Scenario | Behavior |
|----------|----------|
| Another instance running | `RuntimeError: Another instance holds pipeline lock 'homolog_pipeline'` — exits with non-zero |
| Process crashes | MySQL notices connection closed → lock released automatically |
| MySQL server restarts | All advisory locks cleared; any concurrent instance could now acquire |
| Network hiccup drops connection | Lock released; another instance could acquire before original process finishes — rare but possible |

## Inspecting the lock from MySQL

Check if held:
```sql
SELECT IS_USED_LOCK('homolog_pipeline');
```
Returns NULL if not held, or the connection_id of the holder.

Check performance_schema (if enabled) for process info on the holder:
```sql
SELECT * FROM performance_schema.session_connect_attrs
WHERE processlist_id = <id from IS_USED_LOCK>;
```

## Interaction with cron

- `homolog_cron.py` also uses `pipeline_lock`
- If a manual `prepare_jaws.py --monitor` run is active, the next cron cycle will FAIL to acquire and skip
- Cron log will show `RuntimeError: Another instance holds pipeline lock 'homolog_pipeline'`
- This is the intended behavior — cron picks up at the NEXT scheduled cycle

## Related

- Global rule in CLAUDE.md: "Never launch overlapping processes that do the same work"
- For cron's own scheduling: `squeue -u $USER -p cron` shows scrontab jobs
- Before running a manual pipeline, check `SELECT IS_USED_LOCK('homolog_pipeline')` or just try — it fails fast with a clear message
