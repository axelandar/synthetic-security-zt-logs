# Operating the daily dataset

## Schedule and behavior

Enable `Daily-0900-Eastern` only after the cloud integration test passes.
The runbook runs daily at **09:00 America/New_York**: 13:00 UTC during Eastern
Daylight Time and 14:00 UTC during Eastern Standard Time.

Each execution generates ten new random events per Zero Trust table, sixty total.
Event IDs are new and timestamps fall within the preceding sixty minutes.
Manual reruns and concurrent jobs add more events; nothing is skipped by date.
Missed days are not backfilled. No Storage, private endpoint, or Hybrid Worker
is required by this design.

## Verify delivery

```powershell
.\scripts\Test-DailyAutomation.ps1 -ConnectionPath .\.local\connection.json `
  -AutomationPath .\.local\automation.json
```

This starts one real cloud job, adding sixty records. It checks job completion
and six `SENT` messages, reads six `BATCH` receipts, then polls Log Analytics
for the exact ten unique IDs in each destination table. Each ID must appear
exactly once. First-time ingestion can take several minutes.

The runtime identity deliberately has no workspace query permission. Verification
requires an operator with Automation job access and workspace query access.
API acceptance alone is not proof of queryable data.

## Troubleshooting and reruns

- Inspect the Automation job Output and Error streams. `SENT` means the DCR API
  accepted a family; `BATCH` contains its `EventIds` for exact reconciliation.
- A failed family is logged explicitly, remaining families are attempted, and
  the overall job fails. Successful earlier sends remain ingested.
- There is no automatic retry. If a request times out, its acceptance is uncertain.
  Query the available receipts and inspect ingestion health before repeating.
- An intentional rerun generates ten fresh records for **every** table,
  including tables that already succeeded. Extra synthetic data is expected.
- For HTTP 403, verify the account system-assigned identity and its DCR-scoped
  **Monitoring Metrics Publisher** assignment. Allow new RBAC assignments time
  to propagate. Also check DCR networking; do not bypass enforced policy.
- For HTTP 400, inspect stream names, typed schemas, and DCR transformations.
- If managed identity is unavailable, verify the cloud account identity and
  PowerShell 7.4 runtime. No Az modules or stored credentials are needed inside
  the bundled runbook.

See [queries.kql](queries.kql) for daily counts, decisions, exact event IDs, and
Automation failures. Whole-table counts include manual sends and other jobs.

## Alerts and permissions

The deployment sends Automation `JobLogs` and `JobStreams` diagnostics to the
existing workspace and creates a severity-2 metric alert for failed, stopped,
or suspended runbook jobs. Pass `-ActionGroupResourceId` during deployment to
wire notifications. Without it the alert is visible only in Azure and sends
**no email or external notification**.

A schedule that never starts may create no failed job. Check next-run time and
the missing/underfilled-pillars query after 09:00 plus an ingestion grace period.

The runtime needs only Monitoring Metrics Publisher on the DCR: no subscription
Contributor, workspace keys, workspace query role, or Storage permissions.
The deployment operator needs resource deployment and scoped role-assignment rights.

## Upgrade from the former state-backed version

Deploying in incremental mode leaves the former state Storage account and any
old Blob role assignment intact. The new runbook never accesses them. Remove the
obsolete, container-scoped Blob role from the Automation identity after verifying
it is not used elsewhere. Do not delete Storage/data without explicit approval.
Storage public network access remains unchanged. The
[former private-network plan](private-network-plan.md) is superseded.

## Disable and publish

Disable `Daily-0900-Eastern` to stop future jobs; this does not stop a running job.
Disable scheduling before maintenance. Do not delete shared tables, the DCR,
the workspace, or the resource group as a troubleshooting step.

Before publishing on GitHub, run tests, confirm `.local/` and `dist/` are excluded,
review for internal identifiers/secrets, choose a license, and obtain required
organizational approval. Deployment creates no Git repository or remote.
