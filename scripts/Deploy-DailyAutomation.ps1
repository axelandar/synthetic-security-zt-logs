#Requires -Version 7.4
<#
.SYNOPSIS
Deploys managed identity Automation, direct DCR sending, job monitoring, and a daily schedule.
.DESCRIPTION
Requires Az.Accounts, Az.Resources, an existing DCR connection file, and rights
to deploy resources and scoped role assignments in the workspace resource group.
This script publishes the bundled runbook; it does not start an ingestion job.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ConnectionPath,
  [string]$AutomationAccountName = 'aa-synthetic-zt-logs',
  [string]$ActionGroupResourceId,
  [string]$TimeZone = 'America/New_York',
  [switch]$EnableSchedule,
  [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local\automation.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$connection = Get-Content -LiteralPath $ConnectionPath -Raw | ConvertFrom-Json
if ($connection.Cloud -ne 'AzureCloud') { throw 'Daily Automation deployment currently supports Azure public cloud only.' }
if ($connection.WorkspaceResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.OperationalInsights/workspaces/([^/]+)$') {
  throw 'The connection file must include a valid workspace ARM resource ID.'
}
$subscriptionId = $Matches[1]
$resourceGroup = $Matches[2]
if ($connection.DcrResourceId -notmatch "^/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft\.Insights/dataCollectionRules/([^/]+)$") {
  throw 'The DCR and workspace must be in the same resource group for this deployment.'
}
$dcrName = $Matches[1]
$context = Get-AzContext -ErrorAction Stop
if ($null -eq $context -or $context.Tenant.Id -ne $connection.TenantId -or
    $context.Subscription.Id -ne $subscriptionId -or $context.Environment.Name -ne 'AzureCloud') {
  throw 'Sign in to the connection file tenant and subscription in AzureCloud before deploying.'
}
function Invoke-AutomationArm {
  param([string]$Path, [string]$Method, [string]$Payload, [string]$ContentType = 'application/json')
  $arguments = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
  if ($ContentType -eq 'text/plain') {
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -TenantId $connection.TenantId -ErrorAction Stop).Token
    if ($token -is [Security.SecureString]) { $token = [Net.NetworkCredential]::new('', $token).Password }
    $response = Invoke-WebRequest -Uri "https://management.azure.com$Path" -Method $Method `
      -Headers @{ Authorization = 'Bearer ' + $token } -Body ([Text.Encoding]::UTF8.GetBytes($Payload)) `
      -ContentType 'text/plain' -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
  }
  else {
    if ($Payload) { $arguments.Payload = $Payload }
    $response = Invoke-AzRestMethod @arguments
  }
  if ($response.StatusCode -notin @(200, 201, 202, 204)) {
    throw "ARM $Method $Path failed: HTTP $($response.StatusCode). $($response.Content)"
  }
  $response
}
$workspaceResponse = Invoke-AutomationArm -Path "$($connection.WorkspaceResourceId)?api-version=2022-10-01" -Method GET
$workspace = $workspaceResponse.Content | ConvertFrom-Json
if ($workspace.properties.customerId -ne $connection.WorkspaceId) { throw 'Workspace GUID mismatch.' }
$dcrResponse = Invoke-AutomationArm -Path "$($connection.DcrResourceId)?api-version=2024-03-11" -Method GET
$dcr = $dcrResponse.Content | ConvertFrom-Json
if ($dcr.properties.immutableId -ne $connection.DcrImmutableId) { throw 'DCR immutable ID mismatch.' }
foreach ($family in @('ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications',
    'ZeroTrustData', 'ZeroTrustInfrastructure', 'ZeroTrustNetworks')) {
  if (-not $connection.Streams.PSObject.Properties[$family] -or
      -not $dcr.properties.streamDeclarations.PSObject.Properties[$connection.Streams.$family.StreamName]) {
    throw "The DCR is missing the required '$family' input stream."
  }
}
$accountId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$accountsResponse = Invoke-AutomationArm -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts?api-version=2024-10-23" -Method GET
$existingAccount = ($accountsResponse.Content | ConvertFrom-Json).value | Where-Object { $_.id -eq $accountId }
if ($existingAccount -and (-not $existingAccount.tags.PSObject.Properties['purpose'] -or
    $existingAccount.tags.purpose -ne 'synthetic-zero-trust-logs')) {
  throw 'The Automation account name is already used by an unrelated account.'
}
$parameters = @{
  location = $workspace.location; automationAccountName = $AutomationAccountName
  dcrName = $dcrName; workspaceResourceId = $connection.WorkspaceResourceId
}
if ($ActionGroupResourceId) { $parameters.actionGroupResourceId = $ActionGroupResourceId }
$template = Join-Path $root 'infra\daily-automation.json'
$validation = @(Test-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -TemplateFile $template -TemplateParameterObject $parameters)
if ($validation.Count -gt 0) { throw "Automation template validation failed: $($validation | ConvertTo-Json -Depth 10)" }
$deployment = New-AzResourceGroupDeployment -Name 'synthetic-zero-trust-automation' -ResourceGroupName $resourceGroup `
  -TemplateFile $template -TemplateParameterObject $parameters -Mode Incremental -ErrorAction Stop
if ($deployment.ProvisioningState -ne 'Succeeded') { throw "Automation deployment state: $($deployment.ProvisioningState)." }
$bundle = & (Join-Path $PSScriptRoot 'Build-Runbook.ps1') -ConnectionPath $ConnectionPath
$runbookBase = "$accountId/runbooks/Send-DailyZeroTrustLogs"
Invoke-AutomationArm -Path "${runbookBase}/draft/content?api-version=2024-10-23" -Method PUT `
  -Payload (Get-Content -LiteralPath $bundle -Raw) -ContentType 'text/plain' | Out-Null
Invoke-AutomationArm -Path "${runbookBase}/publish?api-version=2024-10-23" -Method POST | Out-Null
$published = $false
for ($i = 0; $i -lt 30; $i++) {
  $readback = (Invoke-AutomationArm -Path "${runbookBase}?api-version=2024-10-23" -Method GET).Content | ConvertFrom-Json
  if ($readback.properties.state -eq 'Published') { $published = $true; break }
  Start-Sleep -Seconds 5
}
if (-not $published) { throw 'The runbook was not published within the verification window. No schedule was linked.' }
$zone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
$local = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone)
$next = [datetime]::SpecifyKind($local.Date.AddHours(9), 'Unspecified')
if ($next -le $local.AddMinutes(10)) { $next = $next.AddDays(1) }
$start = [datetimeoffset]::new($next, $zone.GetUtcOffset($next)).ToString('o')
$nextRun = $null
if ($EnableSchedule) {
  $scheduleParameters = @{
    automationAccountName = $AutomationAccountName; startTime = $start
    timeZone = $TimeZone
  }
  $scheduleDeployment = New-AzResourceGroupDeployment -Name 'synthetic-zero-trust-schedule' -ResourceGroupName $resourceGroup `
    -TemplateFile (Join-Path $root 'infra\daily-schedule.json') -TemplateParameterObject $scheduleParameters -Mode Incremental -ErrorAction Stop
  if ($scheduleDeployment.ProvisioningState -ne 'Succeeded') { throw 'The daily schedule deployment failed.' }
  Invoke-AutomationArm -Path "$accountId/schedules/Daily-0900-Eastern?api-version=2024-10-23" -Method PATCH `
    -Payload '{"properties":{"isEnabled":true}}' | Out-Null
  $schedule = (Invoke-AutomationArm -Path "$accountId/schedules/Daily-0900-Eastern?api-version=2024-10-23" -Method GET).Content | ConvertFrom-Json
  if (-not $schedule.properties.isEnabled -or $schedule.properties.frequency -ne 'Day' -or
      $schedule.properties.timeZone -ne $TimeZone) { throw 'Schedule verification failed.' }
  $nextRun = $schedule.properties.nextRun
}
else {
  $schedules = (Invoke-AutomationArm -Path "$accountId/schedules?api-version=2024-10-23" -Method GET).Content | ConvertFrom-Json
  if (@($schedules.value | Where-Object { $_.name -eq 'Daily-0900-Eastern' }).Count -gt 0) {
    Invoke-AutomationArm -Path "$accountId/schedules/Daily-0900-Eastern?api-version=2024-10-23" -Method PATCH `
      -Payload '{"properties":{"isEnabled":false}}' | Out-Null
  }
}
$settings = [ordered]@{
  AutomationAccountId = $accountId; AutomationAccountName = $AutomationAccountName
  ResourceGroup = $resourceGroup; RunbookName = 'Send-DailyZeroTrustLogs'
  ManagedIdentityPrincipalId = $deployment.Outputs.principalId.Value
  TimeZone = $TimeZone; DailyLocalTime = '09:00'; NextRun = $nextRun
  ScheduleEnabled = [bool]$EnableSchedule
  DeploymentStatus = $(if ($EnableSchedule) { 'ScheduledDirectDcrDelivery' } else { 'PublishedScheduleDisabled' })
  CountPerTable = 10; TableCount = 6
}
$outputDirectory = Split-Path $OutputPath -Parent
if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory | Out-Null }
$settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Daily Automation is published. Schedule enabled: $([bool]$EnableSchedule). Settings: $OutputPath"
if (-not $ActionGroupResourceId) { Write-Warning 'The failed-job alert is enabled but has no notification action group. Add one to receive notifications.' }
[pscustomobject]$settings
