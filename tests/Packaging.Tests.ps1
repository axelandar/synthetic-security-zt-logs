$projectRoot = Split-Path $PSScriptRoot -Parent
Describe 'Deployable project packaging' {
  It 'builds a self-contained parseable runbook without unresolved tokens' {
    $output = Join-Path $TestDrive 'bundled.ps1'
    & (Join-Path $projectRoot 'scripts\Build-Runbook.ps1') `
      -ConnectionPath (Join-Path $projectRoot 'examples\connection.example.json') `
      -OutputPath $output | Out-Null
    $content = Get-Content -LiteralPath $output -Raw
    $content.Contains('__CONFIGURATION_BASE64__') | Should Be $false
    $content.Contains('__GENERATOR_BASE64__') | Should Be $false
    $content.Contains('__MODULE_BASE64__') | Should Be $false
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($output, [ref]$tokens, [ref]$errors) | Out-Null
    $errors.Count | Should Be 0
  }
  It 'requires no Storage resources and grants only scoped DCR publishing permission' {
    $template = Get-Content -LiteralPath (Join-Path $projectRoot 'infra\daily-automation.json') -Raw | ConvertFrom-Json
    @($template.resources | Where-Object { $_.type -like 'Microsoft.Storage/*' }).Count | Should Be 0
    $roles = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
    $roles.Count | Should Be 1
    @($roles | Where-Object { $_.scope -match 'dataCollectionRules' }).Count | Should Be 1
  }
  It 'uses a daily time-zone-aware schedule with one stable runbook link' {
    $template = Get-Content -LiteralPath (Join-Path $projectRoot 'infra\daily-schedule.json') -Raw | ConvertFrom-Json
    $schedule = $template.resources | Where-Object { $_.type -like '*/schedules' }
    $schedule.properties.frequency | Should Be 'Day'
    $schedule.properties.interval | Should Be 1
    $template.parameters.timeZone.defaultValue | Should Be 'America/New_York'
    @($template.resources | Where-Object { $_.type -like '*/jobSchedules' }).Count | Should Be 1
    ($template.resources | Where-Object { $_.type -like '*/jobSchedules' }).properties.runOn | Should Be ''
    @($template.parameters.PSObject.Properties | Where-Object { $_.Name -eq 'hybridWorkerGroup' }).Count | Should Be 0
  }
  It 'has parseable build deployment and integration scripts' {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Filter '*.ps1' -File) {
      $tokens = $null
      $errors = $null
      [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
      $errors.Count | Should Be 0
    }
  }
}
