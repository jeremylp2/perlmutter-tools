# MongoDB Guide — Phytozome Homolog Databases

## Servers and Databases

| Database | Host | Purpose |
|----------|------|---------|
| `diamond_homologs_v14` | plant-db-4.jgi.lbl.gov | Pairwise homolog collections (from diamond/inparanoid pipeline). Config section: `[mongodb]` |
| `phytozome_v14` | plant-db-4.jgi.lbl.gov | Gene and family documents (NOT homologs). Config section: `[mongodb_genes]` |

**The `[mongodb]` and `[mongodb_genes]` sections in `~/.confFile` have similar names. Always use exact-match parsing (anchor with `$`) to avoid `[mongodb_genes]` overriding `[mongodb]`.**

**CRITICAL: MongoDB is ONLY on plant-db-4. PostgreSQL is on plant-db-7. Never mix.**

## Credentials

All credentials are in `~/.confFile` under `[mongodb]` and `[mongodb_genes]` sections. **NEVER hardcode credentials in code or commands.**

Config fields:
- `dbHost`, `dbName`, `dbUser`, `dbPassword`, `authDatabase` (= `admin`), `mongoimportPath`

There is only one set of credentials (read/write). No separate read-only user is configured.

### Reading credentials in Python

```python
# Using the homolog pipeline config module
from config import get_mongo_config
cfg = get_mongo_config()  # reads ~/.confFile [mongodb] section
# Returns dict: host, database, user, password, auth_database, mongoimport_path
```

### Reading credentials in shell

```bash
# Parse ~/.confFile for the mongodb section
MONGO_HOST=$(awk -F= '/^\[mongodb\]/{found=1} found && /dbHost/{print $2; exit}' ~/.confFile)
MONGO_DB=$(awk -F= '/^\[mongodb\]/{found=1} found && /dbName/{print $2; exit}' ~/.confFile)
MONGO_USER=$(awk -F= '/^\[mongodb\]/{found=1} found && /dbUser/{print $2; exit}' ~/.confFile)
MONGO_PASS=$(awk -F= '/^\[mongodb\]/{found=1} found && /dbPassword/{print $2; exit}' ~/.confFile)
```

## Tool Locations

```
mongosh:      ~/bin/mongosh   (also at /global/cfs/cdirs/jgisftwr/plant/mongo/mongosh)
mongoimport:  /global/cfs/cdirs/jgisftwr/plant/mongo/mongoimport
mongodump:    /global/cfs/cdirs/jgisftwr/plant/mongo/mongodump
mongoexport:  /global/cfs/cdirs/jgisftwr/plant/mongo/mongoexport
```

**NOTE:** `mongosh` is NOT in PATH by default. Use the full path or add `~/bin` to PATH.

## Connecting Interactively

**Always use shell variables for credentials — never inline passwords in command lines (they show in `ps`/`/proc`).**

```bash
MONGO_PASS=$(awk -F= '/^\[mongodb\]$/{f=1;next}/^\[/{f=0}f&&/^dbPassword/{print $2;exit}' ~/.confFile)
~/bin/mongosh --host plant-db-4.jgi.lbl.gov --authenticationDatabase admin \
  -u phillips -p "$MONGO_PASS" diamond_homologs_v14
```

## Collection Naming

Homolog collections: `homologs_{proteomeA}_{proteomeB}` (e.g., `homologs_862_91`)

Each collection contains pairwise homolog records between two proteomes. There are two collections per pair (A→B and B→A).

## Common Operations

### List collections for a proteome
```javascript
// In mongosh:
db.getCollectionNames().filter(c => c.match(/homologs_(862_|_862$)/))
```

### Count documents in a collection
```javascript
db.homologs_862_91.countDocuments()
```

### Check if a collection exists and is non-empty
```javascript
db.homologs_862_91.countDocuments() > 0
```

### Drop collections for a proteome (DESTRUCTIVE)
```javascript
db.getCollectionNames().filter(c => c.match(/^homologs_(\d+)_(\d+)$/) && (c.match(/homologs_862_/) || c.match(/_862$/))).forEach(c => db[c].drop())
```

### Query a specific homolog
```javascript
db.homologs_862_91.find({queryIdentifier: "PAC:12345678"}).limit(5)
```

## Loading Data (mongoimport)

The pipeline's `load_mongo.py` handles this, but for manual loads:

```bash
/global/cfs/cdirs/jgisftwr/plant/mongo/mongoimport \
  --uri="mongodb://USER:PASS@plant-db-4.jgi.lbl.gov/diamond_homologs_v14?authSource=admin" \
  -c homologs_862_91 \
  mongoloader_862_91.json \
  --jsonArray
```

### Collection setup (before import)
Collections should be created with zlib compression:
```javascript
db.createCollection('homologs_862_91', {storageEngine: {wiredTiger: {configString: 'block_compressor=zlib'}}})
```

### Indexes (after import)
```javascript
db.homologs_862_91.createIndex({queryIdentifier: 1}, {background: true})
db.homologs_862_91.createIndex({queryTranscriptName: 1}, {background: true})
```

## Using pymongo in Python

```python
from pymongo import MongoClient
from config import get_mongo_config

cfg = get_mongo_config()
uri = f"mongodb://{cfg['user']}:{cfg['password']}@{cfg['host']}/{cfg['database']}?authSource={cfg['auth_database']}"
client = MongoClient(uri)
db = client[cfg['database']]

# Example: count docs
db.homologs_862_91.count_documents({})

# Example: find
for doc in db.homologs_862_91.find({"queryIdentifier": "PAC:12345678"}):
    print(doc)
```

**NOTE:** pymongo must be pip-installed (`pip install pymongo`). It's not in the conda chado env by default.

## Pipeline Scripts That Use MongoDB

| Script | Tool | Purpose |
|--------|------|---------|
| `pipeline/load_mongo.py` | mongosh + mongoimport | Bulk load JSON into collections |
| `pipeline/store_results.py` | mongosh | Drop/recreate collections |
| `pipeline/resume_load.py` | mongosh + mongoimport | Resume interrupted loads |
| `pipeline/remove_self_hits.py` | pymongo | Remove self-hit records |

## Web Service

The API that serves homolog data to Phytozome lives at:
`~/git/zome-webservices/dbservices/controllers/mongo-controllers.js`

The API groups collections by the FIRST proteome number in the collection name.

## Gotchas

- **Race conditions**: Don't run two `load_mongo.py` processes for the same proteome simultaneously. One will get "already exists" errors.
- **mongosh not in PATH**: Always use full path `~/bin/mongosh` or add to PATH first.
- **No read-only user**: The only configured credentials have full read/write access. Be careful with destructive operations.
- **Collection compression**: Always create collections with `block_compressor=zlib` before importing. The pipeline handles this automatically.
