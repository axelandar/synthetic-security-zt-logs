[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ConnectionPath,
  [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\Send-DailyZeroTrustLogs.ps1')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$configuration = @{
  Connection = Get-Content -LiteralPath $ConnectionPath -Raw | ConvertFrom-Json
  Count = 10
  EventTypes = @('ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications',
    'ZeroTrustData', 'ZeroTrustInfrastructure', 'ZeroTrustNetworks')
}
$template = Get-Content -LiteralPath (Join-Path $root 'runbooks\Send-DailyZeroTrustLogs.ps1') -Raw
$values = @{
  '__CONFIGURATION_BASE64__' = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $configuration -Depth 15 -Compress))
  '__GENERATOR_BASE64__' = [IO.File]::ReadAllBytes((Join-Path $root 'src\Send-SyntheticLogs.ps1'))
  '__MODULE_BASE64__' = [IO.File]::ReadAllBytes((Join-Path $root 'src\DailyDelivery.psm1'))
}
foreach ($key in $values.Keys) { $template = $template.Replace($key, [Convert]::ToBase64String($values[$key])) }
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseInput($template, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Bundled runbook has syntax errors: $errors" }
$directory = Split-Path $OutputPath -Parent
if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
[IO.File]::WriteAllText($OutputPath, $template, [Text.UTF8Encoding]::new($false))
Write-Output $OutputPath
