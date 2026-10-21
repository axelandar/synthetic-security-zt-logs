#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 3.4 -MaximumVersion 4.99 -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' -File | Select-Object -ExpandProperty FullName)
$result = Invoke-Pester -Script $files -PassThru
if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed." }
