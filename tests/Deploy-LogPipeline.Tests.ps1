$syntheticDcrDeployPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Deploy-LogPipeline.ps1'

Describe 'Typed DCR deployment generation' {
  It 'generates fifteen matching table schemas and stream data flows without Azure access' {
    $path = Join-Path $TestDrive 'parameters.json'
    & $syntheticDcrDeployPath -GenerateOnly -ParametersPath $path `
      -TenantId '11111111-1111-4111-8111-111111111111' -WorkspaceId '22222222-2222-4222-8222-222222222222' `
      -WorkspaceResourceId '/subscriptions/33333333-3333-4333-8333-333333333333/resourceGroups/example-rg/providers/Microsoft.OperationalInsights/workspaces/example-workspace' -Location eastus `
      -PublisherObjectId '55555555-5555-4555-8555-555555555555'
    $p = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).parameters
    $p.families.value.Count | Should Be 15
    $p.dataFlows.value.Count | Should Be 15
    foreach ($family in $p.families.value) {
      $stream = "Custom-SyntheticDcr$($family.eventType)"
      $inputColumns = $p.streamDeclarations.value.$stream.columns
      $inputColumns.Count | Should Be $family.columns.Count
      @($inputColumns | Where-Object { $_.name -eq 'TimeGenerated' -and $_.type -eq 'datetime' }).Count | Should Be 1
      @($inputColumns | Where-Object { $_.name -eq 'IsSynthetic' -and $_.type -eq 'boolean' }).Count | Should Be 1
      @($family.columns | Where-Object { $_.name -eq 'TenantId' }).Count | Should Be 0
      @($family.columns | Where-Object { $_.name -eq 'SourceTenantId' -and $_.type -eq 'string' }).Count | Should Be 1
      $flow = $p.dataFlows.value | Where-Object { $_.streams -contains $stream }
      $flow.outputStream | Should Be "Custom-$($family.tableName)"
      $flow.transformKql | Should Match 'SourceTenantId = TenantId'
      $flow.transformKql | Should Match 'project-away TenantId'
      if ($family.eventType -eq 'DeviceEvents') {
        @($family.columns | Where-Object { $_.name -eq 'AdditionalFields' -and $_.type -eq 'dynamic' }).Count | Should Be 1
        @($inputColumns | Where-Object { $_.name -eq 'AdditionalFields' -and $_.type -eq 'string' }).Count | Should Be 1
        $flow.transformKql | Should Match 'AdditionalFields = parse_json\(AdditionalFields\)'
      }
      if ($family.eventType -like 'ZeroTrust*') {
        foreach ($field in @('Pillar', 'Framework', 'Principle', 'Control', 'Decision', 'AccessReason')) {
          @($inputColumns | Where-Object { $_.name -eq $field -and $_.type -eq 'string' }).Count | Should Be 1
        }
        @($inputColumns | Where-Object { $_.name -eq 'RiskScore' -and $_.type -eq 'long' }).Count | Should Be 1
      }
    }
    $p.publisherObjectId.value | Should Be '55555555-5555-4555-8555-555555555555'
  }

  It 'uses a direct DCR and scopes publishing permission to that rule' {
    $template = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra\log-pipeline.json') -Raw | ConvertFrom-Json
    $dcr = $template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
    $dcr.kind | Should Be 'Direct'
    $role = $template.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }
    $role.scope | Should Match 'Microsoft.Insights/dataCollectionRules/'
    $role.properties.roleDefinitionId | Should Match '3913510d-42f4-4e42-8a64-420c390055eb'
  }
}
