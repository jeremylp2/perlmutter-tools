---
description: Search JAMO files by final deliverable project ID, with summaries of file types, library info, and platforms
---

Given argument: $ARGUMENTS

The argument is a final deliverable project ID (numeric). Optionally followed by keywords to filter (e.g. `1384162 pacbio hic`).

## 1. Query JAMO

```bash
module load jamo
jamo report select _id,file_name,file_path,file_status,metadata.type,metadata.content,metadata.library_name,metadata.collaborator_library_name,metadata.sequencing_project_id,metadata.instrument_type,metadata.platform_name,metadata.material_type,metadata.library_creation_specs where metadata.final_deliv_project_id=<PROJECT_ID>
```

Or via Python with sdm_curl for richer output:

```python
import socket; socket.setdefaulttimeout(120)
from sdm_curl import Curl
# Read token from ~/.jamo (line format: "https://jamo.jgi.doe.gov: <token>")
curl = Curl('https://jamo.jgi.doe.gov', appToken=TOKEN)
r = curl.post('api/metadata/pagequery', data={
    'query': {'metadata.final_deliv_project_id': <PROJECT_ID>},
    'fields': ['_id', 'file_name', 'file_path', 'file_status',
               'metadata.type', 'metadata.content',
               'metadata.library_name', 'metadata.collaborator_library_name',
               'metadata.sequencing_project_id', 'metadata.instrument_type',
               'metadata.platform_name', 'metadata.material_type',
               'metadata.library_creation_specs'],
    'cltool': True,
    'limit': 1000,
})
```

## 2. Summarize

Group files by category:
- **PacBio reads**: instrument contains `Sequel` or platform `pacbio`
- **Illumina gDNA**: material_type `gDNA` and platform `illumina`
- **RNA-seq**: material_type `RNA` or library_creation_specs contains `RNASeq`
- **Hi-C**: library_creation_specs contains `Hi-C` or `HiC` or `Omni-C`
- **Assembly**: type `assembly` or files ending in `.mainGenome.fasta`, `.fa.gz`
- **Annotation**: type contains `annotation`
- **Other**: everything else

For each file, show: file_name, library_name, collaborator_library_name, file_status, instrument/platform.

## 3. Related project lookups

The final deliverable project ID can also be looked up in PMO:
- `https://projects.jgi.doe.gov/pmo_webservices/final_deliverable_project/<FDP_ID>`

## Notes

- `file_path` in JAMO is the archive directory; full path = `os.path.join(file_path, file_name)`
- `metadata.collaborator_library_name` is the external/PI library name; `metadata.library_name` is JGI internal
- Some fields (instrument_type, platform_name, material_type) may be empty on older records — check `sow_segment` sub-fields as fallback
- The `collaborator_library_name` field is NOT indexed — global searches on it will time out. Search by `final_deliv_project_id` or `sequencing_project_id` instead.
