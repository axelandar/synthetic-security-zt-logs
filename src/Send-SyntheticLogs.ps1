<#
.SYNOPSIS
Generates synthetic Microsoft-style or iboss events for custom Log Analytics tables.
.DESCRIPTION
Use -Preview to emit JSON without credentials or network requests. Custom templates
support {{Timestamp}}, {{Guid}}, {{User}}, {{UserId}}, {{IPAddress}}, {{DeviceName}},
{{TenantId}}, {{SubscriptionId}}, and {{Sequence}} tokens in string values.
These are representative events, not exact native schemas. See ../README.md.
Supply -IngestionEndpoint, -DcrImmutableId, and -StreamName for DCR ingestion.
Use -AccessToken or sign in with Connect-AzAccount for the selected -Cloud.
The legacy workspace-key API remains available for compatibility only.
#>
[CmdletBinding()]
param(
  [string]$WorkspaceId,
  [string]$WorkspaceKey,
  [string]$IngestionEndpoint,
  [string]$DcrImmutableId,
  [string]$StreamName,
  [string]$DcrConfigPath,
  [System.Security.SecureString]$AccessToken,
  [ValidateSet('Iboss', 'SigninLogs', 'AuditLogs', 'DeviceEvents', 'DeviceNetworkEvents',
    'SecurityEvent', 'AzureActivity', 'OfficeActivity', 'SecurityAlert',
    'ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications', 'ZeroTrustData',
    'ZeroTrustInfrastructure', 'ZeroTrustNetworks', 'Custom')]
  [string]$EventType = 'Iboss',
  [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
  [string]$LogType,
  [ValidateRange(1, 100000)]
  [int]$Count = 20,
  [ValidateRange(1, 1000)]
  [int]$BatchSize = 500,
  [ValidateRange(1, 1440)]
  [int]$LookbackMinutes = 60,
  [string]$TenantId = '11111111-1111-4111-8111-111111111111',
  [string]$SubscriptionId = '22222222-2222-4222-8222-222222222222',
  [ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
  [string]$UserDomain = 'contoso.com',
  [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
  [string]$Cloud = 'AzureCloud',
  [string]$TemplatePath,
  [switch]$Preview,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Signature {
  param([string]$WorkspaceId, [string]$WorkspaceKey, [string]$Date, [int]$ContentLength)
  $stringToHash = "POST`n$ContentLength`napplication/json`nx-ms-date:$Date`n/api/logs"
  $sha256 = [System.Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($WorkspaceKey))
  try {
    $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToHash))
    "SharedKey ${WorkspaceId}:$([Convert]::ToBase64String($hash))"
  }
  finally { $sha256.Dispose() }
}

function New-RandomIp {
  # Documentation-only addresses prevent generated data from implicating real hosts.
  "192.0.2.$(Get-Random -Minimum 1 -Maximum 255)"
}

function Get-IngestionBearerToken {
  if ($null -ne $AccessToken) {
    $token = $AccessToken
  }
  else {
    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
      throw 'DCR ingestion requires -AccessToken or Az.Accounts with an authenticated Connect-AzAccount session.'
    }
    $token = (Get-AzAccessToken -ResourceUrl $monitorResource -TenantId $TenantId -ErrorAction Stop).Token
  }
  if ($token -is [System.Security.SecureString]) {
    $token = [System.Net.NetworkCredential]::new('', $token).Password
  }
  if ($token -isnot [string] -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'No access token was returned for Logs Ingestion. Sign in to the correct Azure cloud and tenant.'
  }
  return $token
}

function Add-IngestionPayload {
  param([object[]]$Records)
  $json = ConvertTo-Json -InputObject $Records -Depth 50 -Compress -WarningAction Stop
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  if ($bytes.Length -gt $maxPayloadBytes) {
    if ($useDcr -and $Records.Count -gt 1) {
      $middle = [int][Math]::Floor($Records.Count / 2)
      Add-IngestionPayload -Records $Records[0..($middle - 1)]
      Add-IngestionPayload -Records $Records[$middle..($Records.Count - 1)]
      return
    }
    if ($useDcr) { throw 'A single event exceeds the 1 MB Logs Ingestion API request limit. Reduce the event/template size.' }
    throw 'Payload exceeds the 30 MB API limit. Reduce -BatchSize or template size.'
  }
  $payloads.Add(@{ Body = $bytes; Count = $Records.Count })
}

function Expand-TemplateValue {
  param($Value, [System.Collections.IDictionary]$Tokens)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) {
    $expanded = $Value
    foreach ($name in $Tokens.Keys) {
      $expanded = $expanded.Replace("{{$name}}", [string]$Tokens[$name])
    }
    if ($expanded -match '\{\{[^{}]+\}\}') {
      throw "Unknown template token in '$expanded'. See Get-Help for supported tokens."
    }
    return $expanded
  }
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
      $result[$property.Name] = Expand-TemplateValue -Value $property.Value -Tokens $Tokens
    }
    return [pscustomobject]$result
  }
  if ($Value -is [array]) {
    $items = @(
      foreach ($item in $Value) { Expand-TemplateValue -Value $item -Tokens $Tokens }
    )
    return ,$items
  }
  return $Value
}

function New-SyntheticEvent {
  param([int]$Sequence)
  $user = @('alice', 'bob', 'charlie', 'diana', 'eve') | Get-Random
  $upn = "$user@$UserDomain"
  $userId = [guid]::NewGuid().ToString()
  $device = 'SYNTH-PC-{0:D3}' -f (Get-Random -Minimum 1 -Maximum 100)
  $deviceId = [guid]::NewGuid().ToString('N')
  $ip = New-RandomIp
  $time = [DateTime]::UtcNow.AddSeconds(-(Get-Random -Minimum 0 -Maximum ($LookbackMinutes * 60))).ToString('o')
  $id = [guid]::NewGuid().ToString()
  $resource = "/subscriptions/$SubscriptionId/resourceGroups/rg-synthetic/providers/Microsoft.Compute/virtualMachines/$device"
  $event = [ordered]@{ TimeGenerated = $time }
  if ($EventType.StartsWith('ZeroTrust', [StringComparison]::Ordinal)) {
    $scenario = ($Sequence - 1) % 3
    $event.EventId = $id
    $event.CorrelationId = $id
    $event.Framework = 'Microsoft Zero Trust'
    $event.Pillar = $EventType.Substring(9)
    $event.PolicyName = "Synthetic-$($event.Pillar)-Policy"
    $event.PolicyVersion = '1.0'
    $event.Decision = @('Allow', 'Block', 'RequireRemediation')[$scenario]
    $event.RiskLevel = @('Low', 'High', 'Medium')[$scenario]
    $event.RiskScore = $(switch ($scenario) {
      0 { Get-Random -Minimum 0 -Maximum 30 }
      1 { Get-Random -Minimum 70 -Maximum 101 }
      2 { Get-Random -Minimum 30 -Maximum 70 }
    })
    $event.UserPrincipalName = $upn
    $event.DeviceName = $device
    $event.SourceIP = $ip
    $event.EvaluationMode = 'SyntheticSimulation'
  }
  switch ($EventType) {
    'Iboss' {
      $domain = @('example.org', 'example.com', 'example.net') | Get-Random
      $event.EventId = $id
      $event.Vendor = 'iboss'
      $event.Product = 'SecureWebGateway'
      $event.EventType = 'web_access'
      $event.Action = @('allow', 'block', 'alert') | Get-Random
      $event.ThreatCategory = @('Malware', 'Phishing', 'C2', 'Adult', 'Unknown', 'SocialMedia') | Get-Random
      $event.Username = $upn
      $event.SourceIp = $ip
      $event.DestinationIp = New-RandomIp
      $event.Url = "https://$domain/api/v1/resource/$($id.Substring(0,8))"
      $event.BytesSent = Get-Random -Minimum 200 -Maximum 200000
      $event.BytesReceived = Get-Random -Minimum 500 -Maximum 5000000
    }
    'SigninLogs' {
      $failed = (Get-Random -Minimum 0 -Maximum 5) -eq 0
      $event.Id = $id
      $event.CreatedDateTime = $time
      $event.UserPrincipalName = $upn
      $event.UserDisplayName = $user
      $event.UserId = $userId
      $event.AppDisplayName = 'Microsoft Office'
      $event.AppId = '00000003-0000-0ff1-ce00-000000000000'
      $event.IPAddress = $ip
      $event.ResultType = $(if ($failed) { '50126' } else { '0' })
      $event.ResultDescription = $(if ($failed) { 'Invalid username or password.' } else { 'Success' })
      $event.ConditionalAccessStatus = $(if ($failed) { 'notApplied' } else { 'success' })
      $event.IsInteractive = $true
      $event.CorrelationId = $id
      $event.DeviceDetail = @{ deviceId = $deviceId; displayName = $device; operatingSystem = 'Windows'; browser = 'Edge' }
      $event.Status = @{
        errorCode = $(if ($failed) { 50126 } else { 0 })
        failureReason = $(if ($failed) { 'Invalid username or password.' } else { '' })
      }
    }
    'AuditLogs' {
      $event.Id = $id
      $event.ActivityDateTime = $time
      $event.ActivityDisplayName = 'Update user'
      $event.OperationName = 'Update user'
      $event.Category = 'UserManagement'
      $event.Result = 'success'
      $event.LoggedByService = 'Core Directory'
      $event.CorrelationId = $id
      $event.InitiatedBy = @{ user = @{ id = $userId; userPrincipalName = $upn; ipAddress = $ip } }
      $event.TargetResources = @(@{ id = $userId; displayName = $user; type = 'User'; userPrincipalName = $upn })
    }
    'DeviceEvents' {
      $event.Timestamp = $time
      $event.DeviceId = $deviceId
      $event.DeviceName = $device
      $event.ActionType = 'AntivirusScanCompleted'
      $event.ReportId = $Sequence
      $event.InitiatingProcessFileName = 'MsMpEng.exe'
      $event.InitiatingProcessAccountName = 'system'
      $event.InitiatingProcessAccountDomain = 'nt authority'
      $event.AdditionalFields = @{ ScanType = 'Quick'; ScanResult = 'Completed' } | ConvertTo-Json -Compress
    }
    'DeviceNetworkEvents' {
      $event.Timestamp = $time
      $event.DeviceId = $deviceId
      $event.DeviceName = $device
      $event.ActionType = 'ConnectionSuccess'
      $event.ReportId = $Sequence
      $event.LocalIP = "10.10.0.$(Get-Random -Minimum 1 -Maximum 255)"
      $event.LocalPort = Get-Random -Minimum 49152 -Maximum 65536
      $event.RemoteIP = $ip
      $event.RemotePort = 443
      $event.RemoteUrl = 'example.com'
      $event.Protocol = 'Tcp'
      $event.InitiatingProcessFileName = 'msedge.exe'
      $event.InitiatingProcessAccountUpn = $upn
    }
    'SecurityEvent' {
      $failed = (Get-Random -Minimum 0 -Maximum 5) -eq 0
      $event.EventID = $(if ($failed) { 4625 } else { 4624 })
      $event.Activity = $(if ($failed) { '4625 - An account failed to log on.' } else { '4624 - An account was successfully logged on.' })
      $event.Computer = "$device.$UserDomain"
      $event.Account = "CONTOSO\$user"
      $event.TargetAccount = "CONTOSO\$user"
      $event.TargetUserName = $user
      $event.TargetDomainName = 'CONTOSO'
      $event.IpAddress = $ip
      $event.LogonType = 3
      $event.Status = $(if ($failed) { '0xc000006d' } else { '0x0' })
      $event.AuthenticationPackageName = 'NTLM'
      $event.EventSourceName = 'Microsoft-Windows-Security-Auditing'
      $event.Channel = 'Security'
    }
    'AzureActivity' {
      $event.EventDataId = $id
      $event.CorrelationId = $id
      $event.SubscriptionId = $SubscriptionId
      $event.ResourceGroup = 'rg-synthetic'
      $event.ResourceId = $resource
      $event.ResourceProviderValue = 'MICROSOFT.COMPUTE'
      $event.OperationNameValue = 'MICROSOFT.COMPUTE/VIRTUALMACHINES/WRITE'
      $event.CategoryValue = 'Administrative'
      $event.ActivityStatusValue = 'Success'
      $event.ActivitySubstatusValue = 'OK'
      $event.Caller = $upn
      $event.CallerIpAddress = $ip
      $event.Level = 'Informational'
      $event.Properties = @{ message = 'Synthetic virtual machine update' }
    }
    'OfficeActivity' {
      $event.OfficeId = $id
      $event.RecordType = 6
      $event.Operation = 'FileAccessed'
      $event.OfficeWorkload = 'SharePoint'
      $event.UserId = $upn
      $event.UserType = 0
      $event.ClientIP = $ip
      $event.ResultStatus = 'Succeeded'
      $event.OrganizationId = $TenantId
      $event.OfficeObjectId = 'https://contoso.sharepoint.com/sites/Synthetic/Shared Documents/Test.docx'
      $event.SourceFileName = 'Test.docx'
      $event.UserAgent = 'SyntheticLogGenerator'
    }
    'SecurityAlert' {
      $event.SystemAlertId = $id
      $event.AlertName = 'Synthetic test alert'
      $event.DisplayName = 'Synthetic test alert'
      $event.AlertSeverity = @('Informational', 'Low', 'Medium', 'High') | Get-Random
      $event.Description = 'Generated test data. No actual threat was detected.'
      $event.ProviderName = 'MDATP'
      $event.VendorName = 'Microsoft'
      $event.ProductName = 'Microsoft Defender for Endpoint'
      $event.AlertType = 'SyntheticTestAlert'
      $event.Status = 'New'
      $event.StartTime = $time
      $event.EndTime = $time
      $event.ProcessingEndTime = $time
      $event.CompromisedEntity = $device
      $event.IsIncident = $false
      $event.Entities = @(@{ Type = 'host'; HostName = $device }, @{ Type = 'ip'; Address = $ip }) | ConvertTo-Json -Compress
    }
    'ZeroTrustIdentity' {
      $event.OperationName = 'EvaluateIdentityAccess'
      $event.Principle = 'Verify explicitly'
      $event.Control = 'Phishing-resistant MFA and identity risk'
      $event.TargetResource = 'Synthetic Finance Portal'
      $event.MfaSatisfied = ($scenario -eq 0)
      $event.AuthenticationMethod = @('FIDO2', 'Password', 'Password')[$scenario]
      $event.AccessReason = @('StrongAuthenticationAndLowRisk', 'HighRiskIdentity', 'MfaRequired')[$scenario]
      $event.UserId = $userId
    }
    'ZeroTrustDevices' {
      $event.OperationName = 'EvaluateDevicePosture'
      $event.Principle = 'Verify explicitly'
      $event.Control = 'Managed compliant device required'
      $event.DeviceId = $deviceId
      $event.IsManaged = $true
      $event.IsCompliant = ($scenario -eq 0)
      $event.DiskEncrypted = ($scenario -ne 1)
      $event.EndpointProtectionHealthy = ($scenario -ne 1)
      $event.MissingPatchCount = @(0, 12, 1)[$scenario]
      $event.AccessReason = @('DeviceCompliant', 'EndpointProtectionUnhealthy', 'PatchRequired')[$scenario]
    }
    'ZeroTrustApplications' {
      $event.OperationName = 'EvaluateApplicationSession'
      $event.Principle = 'Use least privilege access'
      $event.Control = 'Application governance and session restrictions'
      $event.ApplicationName = 'Synthetic Collaboration App'
      $event.ApplicationId = '33333333-3333-4333-8333-333333333333'
      $event.IsSanctioned = ($scenario -ne 1)
      $event.RequestedPermission = @('Files.Read', 'Directory.ReadWrite.All', 'Files.Read')[$scenario]
      $event.SessionControl = @('Standard', 'BlockSession', 'RequireReauthentication')[$scenario]
      $event.AccessReason = @('ApprovedLeastPrivilegeSession', 'UnsanctionedHighPrivilegeApp', 'SessionReauthenticationRequired')[$scenario]
    }
    'ZeroTrustData' {
      $event.OperationName = 'EvaluateDataTransfer'
      $event.Principle = 'Assume breach'
      $event.Control = 'Sensitivity labeling and data loss prevention'
      $event.DataObject = "synthetic-report-$Sequence.docx"
      $event.SensitivityLabel = 'Confidential'
      $event.Destination = @('ManagedSharePoint', 'ExternalPersonalStorage', 'ManagedSharePoint')[$scenario]
      $event.IsEncrypted = ($scenario -eq 0)
      $event.DlpRuleMatched = ($scenario -ne 0)
      $event.TransferBytes = Get-Random -Minimum 1024 -Maximum 1048577
      $event.AccessReason = @('ProtectedApprovedDestination', 'ConfidentialDataExternalTransfer', 'EncryptionRequired')[$scenario]
    }
    'ZeroTrustInfrastructure' {
      $event.OperationName = 'EvaluatePrivilegedChange'
      $event.Principle = 'Use least privilege access'
      $event.Control = 'Just-in-time privileged access and configuration policy'
      $event.TargetResource = $resource
      $event.RequestedRole = 'Virtual Machine Contributor'
      $event.JitAccessApproved = ($scenario -eq 0)
      $event.ApprovalTicket = $(if ($scenario -eq 0) { "SYNTH-$Sequence" } else { '' })
      $event.RequestedDurationMinutes = 30
      $event.ConfigurationCompliant = ($scenario -ne 1)
      $event.AccessReason = @('ApprovedTimeBoundChange', 'NoncompliantPrivilegedChange', 'ApprovalRequired')[$scenario]
    }
    'ZeroTrustNetworks' {
      $event.OperationName = 'EvaluateSegmentConnection'
      $event.Principle = 'Assume breach'
      $event.Control = 'Microsegmentation and encrypted transport'
      $event.SourceSegment = 'Synthetic-Workstations'
      $event.DestinationSegment = @('Synthetic-Applications', 'Synthetic-Management', 'Synthetic-Applications')[$scenario]
      $event.DestinationIP = New-RandomIp
      $event.DestinationPort = @(443, 3389, 443)[$scenario]
      $event.Protocol = 'TCP'
      $event.IsEncrypted = ($scenario -ne 2)
      $event.SegmentPolicyMatched = ($scenario -ne 1)
      $event.AccessReason = @('ApprovedEncryptedPath', 'CrossSegmentAccessDenied', 'EncryptedTransportRequired')[$scenario]
    }
    'Custom' {
      $tokens = [ordered]@{
        Timestamp = $time; Guid = $id; User = $upn; UserId = $userId
        IPAddress = $ip; DeviceName = $device; TenantId = $TenantId
        SubscriptionId = $SubscriptionId; Sequence = $Sequence
      }
      $expanded = Expand-TemplateValue -Value $template -Tokens $tokens
      foreach ($property in $expanded.PSObject.Properties) { $event[$property.Name] = $property.Value }
      $event.TimeGenerated = $time
    }
  }
  $event.TenantId = $TenantId
  $event.Sequence = $Sequence
  $event.IsSynthetic = $true
  $event.SyntheticSource = $EventType
  $event.IngestSource = $(if ($EventType -eq 'Iboss') { 'Synthetic-Iboss-Generator' } else { 'Synthetic-Microsoft-Generator' })
  [pscustomobject]$event
}

if ($EventType -eq 'Custom') {
  if ([string]::IsNullOrWhiteSpace($TemplatePath)) { throw '-TemplatePath is required for -EventType Custom.' }
  $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json
  if ($null -eq $template -or $template -isnot [System.Management.Automation.PSCustomObject]) {
    throw 'The template must contain one JSON object, not an array or scalar.'
  }
}
elseif ($PSBoundParameters.ContainsKey('TemplatePath')) {
  throw '-TemplatePath is only valid with -EventType Custom.'
}

$useDcr = $false
if ($PSBoundParameters.ContainsKey('DcrConfigPath')) {
  foreach ($name in @('IngestionEndpoint', 'DcrImmutableId', 'StreamName')) {
    if ($PSBoundParameters.ContainsKey($name)) { throw "-$name cannot be combined with -DcrConfigPath." }
  }
  $connection = Get-Content -LiteralPath $DcrConfigPath -Raw | ConvertFrom-Json
  foreach ($name in @('IngestionEndpoint', 'DcrImmutableId', 'TenantId', 'Cloud', 'Streams')) {
    if (-not $connection.PSObject.Properties[$name]) { throw "DCR connection file is missing '$name'." }
  }
  foreach ($name in @('TenantId', 'Cloud')) {
    if ($PSBoundParameters.ContainsKey($name) -and (Get-Variable -Name $name -ValueOnly) -ne $connection.$name) {
      throw "-$name does not match the DCR connection file."
    }
  }
  $familyConnection = $connection.Streams.PSObject.Properties[$EventType]
  if ($null -eq $familyConnection) { throw "The DCR connection file has no stream for '$EventType'. Supply a matching DCR and stream explicitly." }
  $IngestionEndpoint = $connection.IngestionEndpoint
  $DcrImmutableId = $connection.DcrImmutableId
  $StreamName = $familyConnection.Value.StreamName
  $TenantId = $connection.TenantId
  $Cloud = $connection.Cloud
  $useDcr = $true
}
foreach ($name in @('IngestionEndpoint', 'DcrImmutableId', 'StreamName', 'AccessToken')) {
  if ($PSBoundParameters.ContainsKey($name)) { $useDcr = $true }
}
if ($useDcr) {
  foreach ($name in @('WorkspaceId', 'WorkspaceKey', 'LogType')) {
    if ($PSBoundParameters.ContainsKey($name)) { throw "-$name cannot be combined with DCR ingestion parameters. The DCR determines the destination table." }
  }
  if ($DcrImmutableId -notmatch '^dcr-[0-9a-f]{32}$') {
    throw '-DcrImmutableId must be the DCR immutable ID (dcr- followed by 32 hexadecimal characters), not its ARM resource ID.'
  }
  if ($StreamName -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
    throw '-StreamName must be the existing DCR input stream name, for example Custom-SyntheticSigninLogs.'
  }
  $monitorDomain = switch ($Cloud) {
    'AzureCloud' { 'monitor.azure.com' }
    'AzureUSGovernment' { 'monitor.azure.us' }
    'AzureChinaCloud' { 'monitor.azure.cn' }
  }
  $monitorResource = "https://$monitorDomain/"
  $endpoint = $null
  if (-not [uri]::TryCreate($IngestionEndpoint, [UriKind]::Absolute, [ref]$endpoint) -or
      $endpoint.Scheme -ne 'https' -or $endpoint.Port -ne 443 -or
      -not $endpoint.Host.EndsWith(".ingest.$monitorDomain", [StringComparison]::OrdinalIgnoreCase) -or
      $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
    throw '-IngestionEndpoint must be the HTTPS logs ingestion base URL of your DCR or DCE for the selected -Cloud, without an API path or query.'
  }
}
elseif (-not $LogType) {
  $LogType = $(if ($EventType -eq 'Iboss') { 'IbossSynthetic' } else { "Synthetic$EventType" })
}
if (-not $useDcr -and $LogType.EndsWith('_CL', [StringComparison]::OrdinalIgnoreCase)) {
  throw '-LogType must be the table prefix without the _CL suffix.'
}

if (-not $Preview -and -not $useDcr) {
  $parsedId = [guid]::Empty
  if (-not [guid]::TryParse($WorkspaceId, [ref]$parsedId)) { throw 'A valid -WorkspaceId GUID is required for ingestion.' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw '-WorkspaceKey is required for ingestion.' }
  # Validate the key before generating data or making any requests.
  $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
  if ($keyBytes.Length -eq 0) { throw '-WorkspaceKey must decode to a nonempty key.' }
  Write-Warning 'The HTTP Data Collector API is out of support as of September 14, 2026. Migrate to the DCR-based Logs Ingestion API. Synthetic data may incur ingestion costs.'
}

# Generate and validate every payload before sending to avoid partial writes on template/size errors.
$events = @(for ($i = 1; $i -le $Count; $i++) { New-SyntheticEvent -Sequence $i })
if ($Preview) {
  ConvertTo-Json -InputObject $events -Depth 50 -WarningAction Stop
  return
}

$maxPayloadBytes = $(if ($useDcr) { 1MB } else { 30MB })
$payloads = [System.Collections.Generic.List[object]]::new()
for ($offset = 0; $offset -lt $events.Count; $offset += $BatchSize) {
  $last = [Math]::Min($offset + $BatchSize, $events.Count) - 1
  Add-IngestionPayload -Records @($events[$offset..$last])
}

if ($useDcr) {
  $uri = "$($IngestionEndpoint.TrimEnd('/'))/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"
  $destination = "DCR $DcrImmutableId stream $StreamName"
}
else {
  $suffix = switch ($Cloud) {
    'AzureCloud' { 'ods.opinsights.azure.com' }
    'AzureUSGovernment' { 'ods.opinsights.azure.us' }
    'AzureChinaCloud' { 'ods.opinsights.azure.cn' }
  }
  $uri = "https://$WorkspaceId.$suffix/api/logs?api-version=2016-04-01"
  $destination = "${LogType}_CL"
}
$sent = 0
foreach ($payload in $payloads) {
  try {
    $body = $payload.Body
    if ($useDcr) {
      # Fetch per request so Az.Accounts can refresh tokens during long runs.
      $headers = @{ Authorization = "Bearer $(Get-IngestionBearerToken)" }
    }
    else {
      $date = [DateTime]::UtcNow.ToString('r')
      $headers = @{
        Authorization = New-Signature -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -Date $date -ContentLength $body.Length
        'Log-Type' = $LogType
        'x-ms-date' = $date
        'time-generated-field' = 'TimeGenerated'
      }
    }
    Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -MaximumRedirection 0 -ErrorAction Stop | Out-Null
  }
  catch {
    throw "Ingestion failed after $sent accepted records. Earlier batches are not rolled back; retrying may duplicate them. $($_.Exception.Message)"
  }
  $sent += $payload.Count
}
Write-Host "Success: API accepted $sent synthetic records for $destination. Query the destination table to confirm availability."
if ($PassThru) { $events }
