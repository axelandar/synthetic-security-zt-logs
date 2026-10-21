#Requires -Version 7.4
<#
.SYNOPSIS
Starts a cloud runbook and verifies its exact sixty event IDs in Log Analytics.
.DESCRIPTION
Every execution sends ten new events to each Zero Trust table, including reruns.
Requires Az.Automation, Az.OperationalInsights, and operator access to the account
and workspace queries. The runbook identity does not need workspace query access.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ConnectionPath,
  [Parameter(Mandatory)][string]$AutomationPath,
  [ValidateRange(2, 30)][int]$IngestionWaitMinutes = 10
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$connection = Get-Content -LiteralPath $ConnectionPath -Raw | ConvertFrom-Json
$automation = Get-Content -LiteralPath $AutomationPath -Raw | ConvertFrom-Json
$context = Get-AzContext -ErrorAction Stop
if ($null -eq $context -or $context.Tenant.Id -ne $connection.TenantId -or
    $connection.WorkspaceResourceId -notlike "/subscriptions/$($context.Subscription.Id)/*") {
  throw 'Select the target tenant and subscription before integration testing.'
}
$account = @{ ResourceGroupName = $automation.ResourceGroup; AutomationAccountName = $automation.AutomationAccountName }
$job = Start-AzAutomationRunbook @account -Name $automation.RunbookName -ErrorAction Stop
Write-Host "Started cloud integration job $($job.JobId); this adds sixty fresh records."
$deadline = [datetime]::UtcNow.AddMinutes(10)
do {
  Start-Sleep -Seconds 10
  $status = Get-AzAutomationJob @account -Id $job.JobId -ErrorAction Stop
} while ($status.Status -notin @('Completed', 'Failed', 'Stopped', 'Suspended') -and [datetime]::UtcNow -lt $deadline)
$records = @(Get-AzAutomationJobOutput @account -Id $job.JobId -Stream Any -ErrorAction Stop)
foreach ($record in $records) { Write-Host $record.Summary }
if ($status.Status -ne 'Completed') { throw "Integration job $($job.JobId) ended with status $($status.Status). No automatic replay." }
if (@($records | Where-Object { $_.Summary -like 'SENT ZeroTrust*' }).Count -ne 6) {
  throw 'The cloud job did not report six successful families.'
}
$receipts = @(
  foreach ($record in $records | Where-Object { $_.Summary -like 'BATCH *' }) {
    $detail = Get-AzAutomationJobOutputRecord @account -JobId $job.JobId -Id $record.StreamRecordId -ErrorAction Stop
    $value = $detail.Value
    if ($value -is [Collections.IDictionary]) { $value = $value['value'] }
    elseif ($value -isnot [string] -and $value.PSObject.Properties['value']) { $value = $value.value }
    if ($value -isnot [string] -or -not $value.StartsWith('BATCH ')) { throw 'Unsupported Automation batch receipt format.' }
    $value.Substring(6) | ConvertFrom-Json
  }
)
$families = @('ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications',
  'ZeroTrustData', 'ZeroTrustInfrastructure', 'ZeroTrustNetworks')
if ($receipts.Count -ne 6) { throw 'Expected six batch receipts from the completed job.' }
$expectedRows = @(
  foreach ($family in $families) {
    $batch = @($receipts | Where-Object { $_.EventType -eq $family })
    if ($batch.Count -ne 1 -or $batch[0].Count -ne 10 -or @($batch[0].EventIds | Select-Object -Unique).Count -ne 10) {
      throw "Expected one receipt with ten unique event IDs for $family."
    }
    $table = $connection.Streams.$family.TableName
    if ($table -notmatch '^SyntheticDcrZeroTrust[A-Za-z]+_CL$') { throw "Unexpected table name '$table'." }
    foreach ($id in $batch[0].EventIds) {
      if ($id -notmatch '^[0-9a-fA-F-]{36}$') { throw "Invalid receipt event ID '$id'." }
      "'$table', '$id'"
    }
  }
)
$tables = @($families | ForEach-Object { $connection.Streams.$_.TableName }) -join ', '
$query = @"
let expected = datatable(TableName:string, EventId:string) [$($expectedRows -join ', ')];
let actual =
  union withsource=TableName $tables
  | where TimeGenerated > ago(2h)
  | where EventId in (expected | project EventId)
  | summarize Copies=count() by TableName, EventId;
expected
| join kind=leftouter actual on TableName, EventId
| summarize Records=countif(Copies == 1), Missing=countif(isnull(Copies)),
            DuplicateIds=countif(Copies > 1) by TableName
| order by TableName asc
"@
$deadline = [datetime]::UtcNow.AddMinutes($IngestionWaitMinutes)
$verified = $false
do {
  Start-Sleep -Seconds 30
  $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $connection.WorkspaceId -Query $query -ErrorAction Stop
  $rows = @($result.Results)
  $validRows = @($rows | Where-Object { [int]$_.Records -eq 10 -and [int]$_.Missing -eq 0 -and [int]$_.DuplicateIds -eq 0 })
  Write-Host "Ingestion check: $($validRows.Count)/6 tables contain all ten batch event IDs exactly once."
  if ($rows.Count -eq 6 -and $validRows.Count -eq 6) {
    $verified = $true
    $rows | Format-Table TableName,Records,Missing,DuplicateIds -AutoSize | Out-Host
    break
  }
} while ([datetime]::UtcNow -lt $deadline)
if (-not $verified) { throw "Job $($job.JobId) completed but its exact sixty records did not become queryable within the verification window." }
Write-Host 'PASS: cloud job generated and ingested ten new unique events in each of six tables.'
[pscustomobject]@{ JobId = $job.JobId; VerifiedTables = 6; VerifiedRecords = 60 }
