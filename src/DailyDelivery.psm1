#Requires -Version 7.4
Set-StrictMode -Version Latest

function Get-DeliveryToken {
  if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) {
    throw 'The Automation managed identity endpoint is unavailable. Enable the Automation account system-assigned identity.'
  }
  $resource = [uri]::EscapeDataString('https://monitor.azure.com/')
  $response = Invoke-RestMethod -Uri "$($env:IDENTITY_ENDPOINT)?resource=$resource" -Method Get `
    -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' } -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($response.access_token)) { throw 'Managed identity returned no Azure Monitor access token.' }
  ConvertTo-SecureString $response.access_token -AsPlainText -Force
}

function Invoke-DailySyntheticLogs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConnectionPath,
    [Parameter(Mandatory)][string]$GeneratorPath,
    [ValidateRange(1, 1000)][int]$Count = 10,
    [ValidateSet('ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications',
      'ZeroTrustData', 'ZeroTrustInfrastructure', 'ZeroTrustNetworks')]
    [string[]]$EventTypes = @('ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications',
      'ZeroTrustData', 'ZeroTrustInfrastructure', 'ZeroTrustNetworks')
  )
  $ErrorActionPreference = 'Stop'
  $configuration = Get-Content -LiteralPath $ConnectionPath -Raw | ConvertFrom-Json
  if ($configuration.Cloud -ne 'AzureCloud') { throw 'The scheduled runbook currently supports Azure public cloud only.' }
  if ($EventTypes.Count -eq 0 -or @($EventTypes | Select-Object -Unique).Count -ne $EventTypes.Count) {
    throw 'EventTypes must contain at least one unique event family, without duplicates.'
  }
  foreach ($family in $EventTypes) {
    if (-not $configuration.Streams.PSObject.Properties[$family]) { throw "Missing connection stream for '$family'." }
  }
  $failures = [Collections.Generic.List[string]]::new()
  foreach ($family in $EventTypes) {
    try {
      $token = Get-DeliveryToken
      $events = @(& $GeneratorPath -DcrConfigPath $ConnectionPath -EventType $family `
        -Count $Count -LookbackMinutes 60 -AccessToken $token -PassThru)
      if ($events.Count -ne $Count) { throw "Expected $Count accepted events but the generator returned $($events.Count)." }
      Write-Output "SENT ${family}: $Count fresh synthetic records accepted by the DCR API."
      $receipt = @{
        EventType = $family; Count = $events.Count
        EventIds = @($events | ForEach-Object { $_.EventId })
        AcceptedUtc = [datetime]::UtcNow.ToString('o')
      }
      Write-Output ('BATCH ' + (ConvertTo-Json -InputObject $receipt -Compress -Depth 5))
    }
    catch {
      $failures.Add("${family}: $($_.Exception.Message)")
      Write-Error -Message "${family}: $($_.Exception.Message)" -ErrorAction Continue
    }
  }
  if ($failures.Count -gt 0) {
    throw "Sending failed for $($failures.Count) stream(s). Earlier successful sends remain ingested; rerunning sends fresh events to every table. $($failures -join ' | ')"
  }
}

Export-ModuleMember -Function Invoke-DailySyntheticLogs
