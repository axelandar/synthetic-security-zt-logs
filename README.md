# Synthetic Security & Zero Trust Logs

[![PowerShell tests](https://github.com/axelandar/synthetic-security-zt-logs/actions/workflows/test.yml/badge.svg)](https://github.com/axelandar/synthetic-security-zt-logs/actions/workflows/test.yml)

**Repeatable security demo telemetry for Azure Monitor and Microsoft Sentinel.**

Generate representative Microsoft-style events, send them through the Logs
Ingestion API, and schedule a small daily Zero Trust dataset without secrets or a
machine that must stay switched on.

> This is synthetic telemetry, not evidence of threats, product enforcement,
> compliance, Zero Trust maturity, or real user/device activity. Events land in
> custom tables, not native Microsoft tables.

> The daily runbook generates fresh random records and sends directly through
> the DCR. No Storage account or Hybrid Worker is required. Every run, including
> a manual rerun, adds another 60 events. Deployment keeps scheduling disabled
> unless you explicitly enable it after verification.

## What you get

- **15 event families:** six Microsoft Zero Trust pillars plus sign-ins, audit,
  Defender-like device/network events, Windows Security, Azure Activity, Microsoft
  365 activity, security alerts, and iboss-style web events.
- **Six daily tables:** 10 new events per Zero Trust pillar, **60 per day**.
- **09:00 America/New_York:** a time-zone-aware Azure Automation daily schedule
  follows daylight saving time.
- **Managed identity:** no workspace keys, application secrets, PATs, SAS tokens,
  or interactive login in the scheduled job.
- **Fresh data on every run:** new event IDs, timestamps, users, devices, and
  risk scores. Manual reruns intentionally add another batch.
- **Portable deployment:** ARM templates, PowerShell deployment/build scripts,
  offline tests, GitHub Actions CI, sample configuration, and KQL queries.

## Architecture

1. A daily schedule starts a bundled PowerShell 7.4 cloud Automation runbook.
2. The runbook obtains an Azure Monitor token from its managed identity.
3. For each of six pillars, it generates 10 new events and sends a UTF-8 JSON
   request to that stream's DCR endpoint.
4. It writes an acceptance message and event-ID receipt for each batch. The
   integration test queries those exact IDs to verify Log Analytics ingestion.

The managed identity needs only **Monitoring Metrics Publisher on the DCR**.
It has no subscription
Contributor role, workspace keys, or workspace query role.

## Quick start: preview locally

Requires PowerShell 7.4+ for deployment/runbooks/tests. The standalone generator
also supports Windows PowerShell 5.1.

```powershell
git clone https://github.com/axelandar/synthetic-security-zt-logs.git
Set-Location .\synthetic-security-zt-logs
.\src\Send-SyntheticLogs.ps1 -EventType ZeroTrustIdentity -Count 10 -Preview
```

Ten Zero Trust events contain 4 `Allow`, 3 `Block`, and 3 `RequireRemediation`
evaluations. Context and risk scores are randomized; the scenario cycle is
intentional so every small demo has useful outcomes.

## Deploy to your Azure workspace

### Prerequisites

- An existing Azure public-cloud Log Analytics workspace.
- A PowerShell session with Az.Accounts and Az.Resources.
- Rights to deploy tables, a DCR, Automation, monitoring resources, and
  scoped role assignments. The scripts never grant the runbook broad management
  permissions.
- A resource group where the workspace and DCR reside together.
- A DCR ingestion endpoint reachable from the Automation cloud sandbox.

The daily deployment supports Azure public cloud. The standalone sender also
supports existing sovereign-cloud DCR endpoints. No GitHub authentication is
needed for Azure deployment.

```powershell
Connect-AzAccount -Tenant '<tenant-id>' -Environment AzureCloud
Set-AzContext -Subscription '<subscription-id>'
New-Item -ItemType Directory .\.local -Force | Out-Null

# For a new pipeline, create the 15 typed tables and DCR.
.\scripts\Deploy-LogPipeline.ps1 `
  -TenantId '<tenant-id>' `
  -WorkspaceId '<workspace-guid>' `
  -WorkspaceResourceId '<workspace-arm-resource-id>' `
  -Location '<workspace-region>'

# For an existing pipeline, instead put its connection settings in .local/connection.json.
# See examples/connection.example.json.

.\scripts\Deploy-DailyAutomation.ps1 -ConnectionPath .\.local\connection.json
```

The second script creates and publishes the bundled runbook and writes
`.local/automation.json`. It **keeps the schedule disabled by default** and does
not start a job. After a successful integration test, enable explicitly:

```powershell
.\scripts\Deploy-DailyAutomation.ps1 -ConnectionPath .\.local\connection.json `
  -EnableSchedule
```

A future daily schedule starts at the next 09:00 occurrence,
at least ten minutes ahead.
Allow a few minutes for new RBAC assignments to propagate before the first manual
test. Deployment uses incremental mode and never deletes the workspace or tables.

Optional: pass `-ActionGroupResourceId '<existing-action-group-arm-id>'` to wire
failed-job notifications. Without it, the alert exists in Azure but sends **no
email or external notification**.

## Start and inspect a job

Requires Az.Automation on the operator's machine, not in the runbook.

```powershell
$deployment = Get-Content .\.local\automation.json -Raw | ConvertFrom-Json
$job = Start-AzAutomationRunbook `
  -ResourceGroupName $deployment.ResourceGroup `
  -AutomationAccountName $deployment.AutomationAccountName `
  -Name $deployment.RunbookName

Get-AzAutomationJob -Id $job.JobId `
  -ResourceGroupName $deployment.ResourceGroup `
  -AutomationAccountName $deployment.AutomationAccountName

Get-AzAutomationJobOutput -Id $job.JobId `
  -ResourceGroupName $deployment.ResourceGroup `
  -AutomationAccountName $deployment.AutomationAccountName -Stream Any |
  Get-AzAutomationJobOutputRecord
```

Expected: six `SENT` messages and six `BATCH` event-ID receipts on every run.
Each run adds ten fresh events per table. There is no daily skip or deduplication.
The repeatable integration test is:

```powershell
.\scripts\Test-DailyAutomation.ps1 -ConnectionPath .\.local\connection.json `
  -AutomationPath .\.local\automation.json
```

This starts one cloud job and verifies its exact 60 IDs, ten per table, appear
once each. API acceptance alone does not establish query availability.

## Query the dataset

```kusto
union SyntheticDcrZeroTrust*
| where TimeGenerated > ago(24h) and IsSynthetic == true
| summarize Records=count() by Pillar, Decision
| order by Pillar asc, Decision asc
```

Use [queries.kql](docs/queries.kql) for daily counts, blocked decisions, and
Automation failures. Counts can include manually generated records. Use the
job's `BATCH` receipt `EventIds` to identify the scheduled batch precisely.

## Tables and event families

See the [generator guide](docs/generator.md) for custom JSON templates, manual
ingestion, batching, sovereign-cloud sending, and legacy compatibility.

| `-EventType` | Custom table | Representative signals |
|---|---|---|
| `ZeroTrustIdentity` | `SyntheticDcrZeroTrustIdentity_CL` | MFA satisfaction, authentication method, risk |
| `ZeroTrustDevices` | `SyntheticDcrZeroTrustDevices_CL` | Managed/compliant state, patches, encryption |
| `ZeroTrustApplications` | `SyntheticDcrZeroTrustApplications_CL` | Sanctioned apps, permissions, session controls |
| `ZeroTrustData` | `SyntheticDcrZeroTrustData_CL` | Labels, DLP, destinations, encryption |
| `ZeroTrustInfrastructure` | `SyntheticDcrZeroTrustInfrastructure_CL` | JIT privilege, approvals, configuration |
| `ZeroTrustNetworks` | `SyntheticDcrZeroTrustNetworks_CL` | Segmentation, ports, encrypted connections |
| `SigninLogs` | `SyntheticDcrSigninLogs_CL` | Successful/failed sign-ins |
| `AuditLogs` | `SyntheticDcrAuditLogs_CL` | Directory changes |
| `DeviceEvents` | `SyntheticDcrDeviceEvents_CL` | Antivirus scan completion |
| `DeviceNetworkEvents` | `SyntheticDcrDeviceNetworkEvents_CL` | Device network connections |
| `SecurityEvent` | `SyntheticDcrSecurityEvent_CL` | Windows 4624/4625 logons |
| `AzureActivity` | `SyntheticDcrAzureActivity_CL` | Resource changes |
| `OfficeActivity` | `SyntheticDcrOfficeActivity_CL` | SharePoint file access |
| `SecurityAlert` | `SyntheticDcrSecurityAlert_CL` | Clearly synthetic Defender-like alerts |
| `Iboss` | `SyntheticDcrIboss_CL` | Web access |

Only the six Zero Trust families are scheduled. The other nine remain available
for interactive generation. Shared metadata includes `IsSynthetic`,
`SyntheticSource`, and `IngestSource`. DCR transformations preserve the supplied
tenant as `SourceTenantId` because Azure owns the destination `TenantId` column.

## Delivery guarantees and limitations

**Every run generates fresh data; there is no deduplication or exactly-once guarantee.**

- Each normal run adds 60 events. Manual/concurrent reruns add further events.
- A timeout or crash after sending may mean some events were accepted.
- `SENT` means API acceptance, not that a query returned rows.
- Other tables continue when a single table fails; the overall job then fails.
- No automatic retries or missed-day backfill. A rerun generates new events for
  every table, including ones that succeeded previously.
- Event timestamps are randomized within the preceding 60 minutes.

See the [operations guide](docs/operations.md) for monitoring and troubleshooting.

## Security, cost, and publishing

- No Storage account, state container, or Hybrid Worker is provisioned or needed.
  Incremental upgrades retain older unused Storage resources; removal is a
  separate, deliberate operator action. Network policy is not changed.
- Costs include Automation execution, 60 events/day, Automation
  diagnostic logs, and an Azure Monitor alert. This is not a cost-free promise.
- Failed-job alerts detect failed/stopped/suspended jobs, not a schedule that
  never starts. Monitor the daily-count query for missing data.
- Keep environment-specific settings in ignored `.local/`; generated bundles
  go into ignored `dist/`. Do not commit tokens, Azure contexts, or actual
  tenant-specific deployment parameters.
- No repository is created or pushed by these scripts. Choose a license and
  review organizational publication approval before releasing on GitHub.

## Development

### License status

No license has been selected yet. Public availability does not grant a general
license to reuse, modify, or redistribute this project. Licensing remains pending
review.

### Run tests

```powershell
.\scripts\Test.ps1
```

Tests use Pester 3.4-4.10 (CI pins 4.10.1) and require no Azure login.
They cover all 15 generators, typed DCR schemas, UTF-8 request limits/signatures,
six-table delivery, fresh identifiers on reruns, explicit sending failures,
managed identity authentication, infrastructure settings, and self-contained packaging.

```text
src/        Event generator and direct daily delivery module
runbooks/   Managed identity entry point, bundled at deployment
infra/      Typed log pipeline, daily infrastructure, and schedule templates
scripts/    Build, deploy, and test commands
tests/      Offline regression tests
examples/   Fictional, safe-to-publish configuration
docs/       Operational recovery and KQL queries
.local/     Ignored environment-specific configuration
dist/       Ignored generated runbook bundle
```

### References

- [Microsoft Zero Trust framework](https://learn.microsoft.com/en-us/security/zero-trust/zero-trust-overview)
- [Logs Ingestion API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [Automation runtime environments](https://learn.microsoft.com/en-us/azure/automation/runtime-environment-overview)
- [Automation managed identity HTTP authentication](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
