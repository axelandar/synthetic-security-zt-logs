#Requires -Version 7.4
<#
.SYNOPSIS
Daily managed identity entry point, bundled by Build-Runbook.ps1.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$configuration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIGURATION_BASE64__')) | ConvertFrom-Json
$work = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
try {
  $generatorPath = Join-Path $work 'Send-SyntheticLogs.ps1'
  $modulePath = Join-Path $work 'DailyDelivery.psm1'
  $connectionPath = Join-Path $work 'connection.json'
  [IO.File]::WriteAllBytes($generatorPath, [Convert]::FromBase64String('__GENERATOR_BASE64__'))
  [IO.File]::WriteAllBytes($modulePath, [Convert]::FromBase64String('__MODULE_BASE64__'))
  $configuration.Connection | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $connectionPath -Encoding UTF8
  Import-Module $modulePath -Force -ErrorAction Stop
  Invoke-DailySyntheticLogs -ConnectionPath $connectionPath -GeneratorPath $generatorPath `
    -EventTypes $configuration.EventTypes -Count $configuration.Count
}
finally {
  Remove-Module DailyDelivery -Force -ErrorAction SilentlyContinue
  foreach ($name in @('Send-SyntheticLogs.ps1', 'DailyDelivery.psm1', 'connection.json')) {
    $file = Join-Path $work $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
  }
  Remove-Item -LiteralPath $work -ErrorAction Stop
}
