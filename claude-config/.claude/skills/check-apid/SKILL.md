---
description: Check JAMO analysis project ID(s) for a proteome, reporting any inconsistencies across files
---

Given proteome ID(s): $ARGUMENTS

For each proteome ID provided (comma-separated), do the following:

1. Run `module load jamo` then query JAMO via Python using `sdm_curl`:
   ```python
   from sdm_curl import Curl
   curl = Curl('https://jamo.jgi.doe.gov', appToken=<token from ~/.jamo>)
   r = curl.post('api/metadata/pagequery', data={
       'query': {'metadata.phytozome.phytozome_genome_id': <proteome_id>},
       'fields': ['_id', 'file_name', 'metadata.analysis_project_id',
                  'metadata.analysis_project.analysis_project_id',
                  'metadata.analysis_project.analysis_project_name',
                  'metadata.analysis_project.visibility'],
       'cltool': True,
   })
   ```

2. For each file record, extract:
   - `metadata.analysis_project_id` (top-level)
   - `metadata.analysis_project.analysis_project_id` (nested)
   - `metadata.analysis_project.analysis_project_name`
   - `metadata.analysis_project.visibility`

3. Report:
   - The analysis project ID if consistent across all files
   - The visibility status from `metadata.analysis_project.visibility`
   - If multiple different analysis_project_ids are found across files, list each one with the count of files and file names
   - If no analysis_project_id is found on any file, report that clearly

4. Use `socket.setdefaulttimeout(120)` before importing sdm_curl.

5. Read the JAMO token from `~/.jamo` (line format: `https://jamo.jgi.doe.gov: <token>`).

Print a concise summary table with columns: proteome_id, analysis_project_id, analysis_project_name, visibility, file_count, notes (inconsistencies if any).
