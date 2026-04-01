---
description: Look up PMO analysis project for a proteome — visibility, embargo, collaborators, status
---

Given proteome ID(s): $ARGUMENTS

For each proteome ID (comma-separated):

## 1. Get APID from Phytozome API

`https://phytozome-next.jgi.doe.gov/api/db/properties/proteome/<PID>` — returns a list, use `[0]`. Check `xrefs` array for entry with `dbname=JGIAP`; the `accession` field has the analysis project ID.

If no JGIAP xref, report as external genome and stop.

## 2. Get analysis project details

`https://projects.jgi.doe.gov/pmo_webservices/analysis_project/<APID>` — response under `uss_analysis_project`.

Report:
- `analysis_project_name`
- `visibility` (DataAvailable, Private, etc.)
- `status_name` (Complete, In Progress, etc.)
- `embargo_days`
- `availability_date`
- `pi_contact_id`

## 3. Get collaborators

`https://projects.jgi.doe.gov/pmo_webservices/collaborators_for_project_hierarchy/<APID>`

Report:
- `project_manager` (name, email)
- All collaborators with: role, name, institution, email, level

## 4. Check analysis tasks

From the analysis project response, `analysis_tasks` array. Report each task's:
- `analysis_task_type_name` (DNA Assembly, Annotation Phytozome, etc.)
- `status_name`

## 5. Check sequencing projects

From the analysis project response, `sequencing_projects` array. Report IDs and names.

## Output

Print a concise summary for each proteome.
