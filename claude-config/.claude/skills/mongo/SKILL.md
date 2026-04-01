---
description: Connect to Phytozome MongoDB and optionally run a query
---

Connect to the Phytozome MongoDB. Arguments: $ARGUMENTS

Read `~/.claude/mongo-guide.md` for full reference.

## Steps

1. Parse credentials from `~/.confFile`:
   - Default: `[mongodb]` section → `diamond_homologs_v14` (homolog collections)
   - If user says "genes" or "gene database": `[mongodb_genes]` section → `phytozome_v14` (gene/family documents)
   - Fields: `dbHost`, `dbName`, `dbUser`, `dbPassword`, `authDatabase`
   - **NEVER echo, print, or display the password.** Use it only inside connection strings passed to mongosh/pymongo.
   - **CRITICAL: Use exact-match `[mongodb]$` in awk (anchor with `$`) to avoid `[mongodb_genes]` overriding values.**

2. **Password safety: ALWAYS use shell variables, never inline passwords in command lines.**
   Use this pattern to parse credentials into variables (password stays in process memory, not visible in `ps`/`/proc`):
   ```bash
   SECT="mongodb"  # or "mongodb_genes" for gene database
   MONGO_HOST=$(awk -F= "/^\[${SECT}\]$/{f=1;next}/^\[/{f=0}f&&/^dbHost/{print \$2;exit}" ~/.confFile)
   MONGO_DB=$(awk -F= "/^\[${SECT}\]$/{f=1;next}/^\[/{f=0}f&&/^dbName/{print \$2;exit}" ~/.confFile)
   MONGO_USER=$(awk -F= "/^\[${SECT}\]$/{f=1;next}/^\[/{f=0}f&&/^dbUser/{print \$2;exit}" ~/.confFile)
   MONGO_PASS=$(awk -F= "/^\[${SECT}\]$/{f=1;next}/^\[/{f=0}f&&/^dbPassword/{print \$2;exit}" ~/.confFile)
   MONGO_AUTH=$(awk -F= "/^\[${SECT}\]$/{f=1;next}/^\[/{f=0}f&&/^authDatabase/{print \$2;exit}" ~/.confFile)
   ```
   Then connect with: `~/bin/mongosh --host "$MONGO_HOST" --authenticationDatabase "$MONGO_AUTH" -u "$MONGO_USER" -p "$MONGO_PASS" "$MONGO_DB" --quiet --eval '<JS>'`

3. Determine what the user wants:

   **If no arguments or "connect"**: Tell the user to run this interactively with `!`:
   ```
   ! MONGO_PASS=$(awk -F= '/^\[mongodb\]$/{f=1;next}/^\[/{f=0}f&&/^dbPassword/{print $2;exit}' ~/.confFile) && ~/bin/mongosh --host plant-db-4.jgi.lbl.gov --authenticationDatabase admin -u phillips -p "$MONGO_PASS" diamond_homologs_v14
   ```

   **If "genes" or "gene database"**: Same but use the `[mongodb_genes]` section and its dbName.

   **If a query is provided** (e.g., `/mongo count homologs_862_91`, `/mongo list collections for 862`, `/mongo find in homologs_862_91 where queryIdentifier=PAC:12345`):
   Run it non-interactively via the Bash tool using the variable pattern above with `--quiet --eval`.

4. Common query patterns:
   - `list collections for <N>`: `db.getCollectionNames().filter(c => c.match(/homologs_(<N>_|_<N>$)/))`
   - `count <collection>`: `db.<collection>.countDocuments({})`
   - `count all for <N>`: iterate matching collections, sum counts
   - `find <query> in <collection>`: `db.<collection>.find(<query>).limit(10)`
   - `stats`: `db.stats()`
   - `drop <collection>`: **Ask for confirmation first.** Then `db.<collection>.drop()`

5. Collection naming convention: `homologs_{proteomeA}_{proteomeB}` in the `diamond_homologs_v14` database.
