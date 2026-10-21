<#
.SYNOPSIS
Deploys typed synthetic log tables, a direct ingestion DCR, and scoped publisher RBAC.
.DESCRIPTION
Requires Az.Accounts, Az.Resources, and an authenticated session in the target tenant
and subscription. Uses an incremental ARM deployment; no workspace keys or secrets
are written. The invoking principal needs resource deployment and role assignment rights.
Use -GenerateOnly to write deployment parameters without authentication or Azure changes.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TenantId,
  [Parameter(Mandatory)][string]$WorkspaceId,
  [Parameter(Mandatory)][string]$WorkspaceResourceId,
  [ValidatePattern('^[A-Za-z0-9_-]+$')]
  [string]$DcrName = 'dcr-synthetic-msft-logs',
  [string]$PublisherObjectId,
  [ValidateSet('User', 'ServicePrincipal')]
  [string]$PublisherPrincipalType = 'User',
  [Parameter(Mandatory)][string]$Location,
  [string]$ParametersPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local\pipeline.parameters.json'),
  [string]$ConnectionPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local\connection.json'),
  [switch]$GenerateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($WorkspaceResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.OperationalInsights/workspaces/([^/]+)$') {
  throw '-WorkspaceResourceId must be a Log Analytics workspace ARM resource ID.'
}
$targetSubscription = $Matches[1]
$resourceGroup = $Matches[2]
$workspaceName = $Matches[3]

if (-not $GenerateOnly) {
  $context = Get-AzContext -ErrorAction Stop
  if ($null -eq $context -or $context.Tenant.Id -ne $TenantId -or
      $context.Subscription.Id -ne $targetSubscription -or $context.Environment.Name -ne 'AzureCloud') {
    throw "Sign in to tenant $TenantId in AzureCloud and select subscription $targetSubscription before deploying."
  }
  $response = Invoke-AzRestMethod -Path "${WorkspaceResourceId}?api-version=2022-10-01" -Method GET -ErrorAction Stop
  if ($response.StatusCode -ne 200) { throw "Workspace lookup failed: HTTP $($response.StatusCode). $($response.Content)" }
  $workspace = $response.Content | ConvertFrom-Json
  if ($workspace.properties.customerId -ne $WorkspaceId) { throw 'The workspace resource ID does not match the requested workspace GUID.' }
  $Location = $workspace.location
  if (-not $PublisherObjectId) {
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -TenantId $TenantId -ErrorAction Stop).Token
    if ($token -is [System.Security.SecureString]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
    $parts = $token.Split('.')
    if ($parts.Count -ne 3) { throw 'Cannot determine the signed-in publisher object ID from the management token. Supply -PublisherObjectId.' }
    $encoded = $parts[1].Replace('-', '+').Replace('_', '/')
    $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    $PublisherObjectId = $claims.oid
    $token = $null
  }
}
if ($PublisherObjectId) {
  $parsedId = [guid]::Empty
  if (-not [guid]::TryParse($PublisherObjectId, [ref]$parsedId)) { throw '-PublisherObjectId must be an Entra object GUID.' }
}
elseif (-not $GenerateOnly) { throw 'A publisher object ID is required to assign DCR ingestion permission.' }

$generator = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Send-SyntheticLogs.ps1'
$families = @()
$streams = [ordered]@{}
$flows = @()
$connections = [ordered]@{}
foreach ($family in @('Iboss', 'SigninLogs', 'AuditLogs', 'DeviceEvents', 'DeviceNetworkEvents',
    'SecurityEvent', 'AzureActivity', 'OfficeActivity', 'SecurityAlert',
    'ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications', 'ZeroTrustData',
    'ZeroTrustInfrastructure', 'ZeroTrustNetworks')) {
  $sample = (& $generator -EventType $family -Count 1 -TenantId $TenantId -Preview | ConvertFrom-Json)[0]
  $inputColumns = @(
    foreach ($property in $sample.PSObject.Properties) {
      $type = 'string'
      if ($property.Name -in @('TimeGenerated', 'Timestamp', 'CreatedDateTime', 'ActivityDateTime',
          'StartTime', 'EndTime', 'ProcessingEndTime')) { $type = 'datetime' }
      elseif ($property.Value -is [bool]) { $type = 'boolean' }
      elseif ($property.Value -is [int] -or $property.Value -is [long]) { $type = 'long' }
      elseif ($property.Value -is [array] -or $property.Value -is [System.Management.Automation.PSCustomObject]) { $type = 'dynamic' }
      @{ name = $property.Name; type = $type }
    }
  )
  # TenantId is a platform-owned workspace column; preserve the source tenant separately.
  $outputColumns = @(
    foreach ($column in $inputColumns) {
      if ($column.name -eq 'TenantId') { @{ name = 'SourceTenantId'; type = 'string' } }
      elseif ($column.name -eq 'AdditionalFields') { @{ name = 'AdditionalFields'; type = 'dynamic' } }
      else { $column }
    }
  )
  $table = "SyntheticDcr${family}_CL"
  $stream = "Custom-SyntheticDcr$family"
  $families += @{ eventType = $family; tableName = $table; columns = $outputColumns }
  $streams[$stream] = @{ columns = $inputColumns }
  $transform = 'source | extend SourceTenantId = TenantId | project-away TenantId'
  if ($family -eq 'DeviceEvents') {
    $transform = 'source | extend SourceTenantId = TenantId, AdditionalFields = parse_json(AdditionalFields) | project-away TenantId'
  }
  $flows += @{
    streams = @($stream); destinations = @('syntheticWorkspace')
    transformKql = $transform
    outputStream = "Custom-$table"
  }
  $connections[$family] = @{ StreamName = $stream; TableName = $table }
}

$parameters = @{
  workspaceName = $workspaceName; location = $Location; dcrName = $DcrName
  families = $families; streamDeclarations = $streams; dataFlows = $flows
  publisherObjectId = $PublisherObjectId; publisherPrincipalType = $PublisherPrincipalType
}
$parameterFile = [ordered]@{
  '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters = [ordered]@{}
}
foreach ($name in $parameters.Keys) { $parameterFile.parameters[$name] = @{ value = $parameters[$name] } }
ConvertTo-Json -InputObject $parameterFile -Depth 30 -WarningAction Stop |
  Set-Content -LiteralPath $ParametersPath -Encoding UTF8
if ($GenerateOnly) {
  Write-Host "Generated parameters: $ParametersPath. Supply publisherObjectId before deployment."
  return
}

$template = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\log-pipeline.json'
$response = Invoke-AzRestMethod -Path "${WorkspaceResourceId}/tables?api-version=2022-10-01" -Method GET -ErrorAction Stop
if ($response.StatusCode -ne 200) { throw "Table preflight failed: HTTP $($response.StatusCode). $($response.Content)" }
$existingTables = @(($response.Content | ConvertFrom-Json).value)
foreach ($family in $families) {
  $existing = $existingTables | Where-Object { ($_.name -split '/')[-1] -eq $family.tableName }
  if ($null -ne $existing) {
    $expected = @($family.columns | ForEach-Object { "$($_.name):$($_.type)" } | Sort-Object)
    $actual = @($existing.properties.schema.columns | ForEach-Object { "$($_.name):$($_.type)" } | Sort-Object)
    if (Compare-Object -ReferenceObject $expected -DifferenceObject $actual) {
      throw "Existing table '$($family.tableName)' has a different schema. No deployment was started."
    }
  }
}
$dcrResourceId = "/subscriptions/$targetSubscription/resourceGroups/$resourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
$response = Invoke-AzRestMethod -Path "/subscriptions/$targetSubscription/resourceGroups/$resourceGroup/providers/Microsoft.Insights/dataCollectionRules?api-version=2024-03-11" -Method GET -ErrorAction Stop
if ($response.StatusCode -ne 200) { throw "DCR preflight failed: HTTP $($response.StatusCode). $($response.Content)" }
$existingDcr = ($response.Content | ConvertFrom-Json).value | Where-Object { $_.id -eq $dcrResourceId }
if ($null -ne $existingDcr) {
  if (-not $existingDcr.tags.PSObject.Properties['purpose'] -or $existingDcr.tags.purpose -ne 'synthetic-log-testing' -or
      $existingDcr.properties.destinations.logAnalytics[0].workspaceResourceId -ne $WorkspaceResourceId) {
    throw "A DCR named '$DcrName' already exists and does not match this deployment. No deployment was started."
  }
  foreach ($existingStream in $existingDcr.properties.streamDeclarations.PSObject.Properties.Name) {
    if (-not $streams.Contains($existingStream)) {
      throw "Existing DCR stream '$existingStream' is not in this deployment. Refusing to remove an existing stream."
    }
  }
}
$validation = @(Test-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -TemplateFile $template -TemplateParameterFile $ParametersPath -ErrorAction Stop)
if ($validation.Count -gt 0) { throw "ARM validation failed: $($validation | ConvertTo-Json -Depth 10 -Compress)" }
$deployment = New-AzResourceGroupDeployment -Name 'synthetic-logs' -ResourceGroupName $resourceGroup `
  -TemplateFile $template -TemplateParameterFile $ParametersPath -Mode Incremental -ErrorAction Stop
if ($deployment.ProvisioningState -ne 'Succeeded') { throw "Deployment did not succeed: $($deployment.ProvisioningState)" }
$connection = [ordered]@{
  TenantId = $TenantId; Cloud = 'AzureCloud'; WorkspaceId = $WorkspaceId
  WorkspaceResourceId = $WorkspaceResourceId
  IngestionEndpoint = $deployment.Outputs.ingestionEndpoint.Value
  DcrImmutableId = $deployment.Outputs.dcrImmutableId.Value
  DcrResourceId = $deployment.Outputs.dcrResourceId.Value
  Streams = $connections
}
ConvertTo-Json -InputObject $connection -Depth 10 -WarningAction Stop |
  Set-Content -LiteralPath $ConnectionPath -Encoding UTF8
Write-Host "Deployed $($families.Count) typed tables and DCR. Non-secret connection settings: $ConnectionPath"
[pscustomobject]$connection
