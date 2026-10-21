Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DailyDelivery.psm1') -Force

InModuleScope DailyDelivery {
  Describe 'Automation managed identity authentication' {
    BeforeEach {
      $savedEndpoint = $env:IDENTITY_ENDPOINT
      $savedHeader = $env:IDENTITY_HEADER
      $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:12345/identity'
      $env:IDENTITY_HEADER = 'test-identity-header'
      Mock Invoke-RestMethod { @{ access_token = 'test-monitor-token' } }
    }
    AfterEach {
      $env:IDENTITY_ENDPOINT = $savedEndpoint
      $env:IDENTITY_HEADER = $savedHeader
    }
    It 'requests the Monitor audience and passes the Automation identity header' {
      $token = Get-DeliveryToken
      ($token -is [Security.SecureString]) | Should Be $true
      [Net.NetworkCredential]::new('', $token).Password | Should Be 'test-monitor-token'
      Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
        $Uri -eq 'http://127.0.0.1:12345/identity?resource=https%3A%2F%2Fmonitor.azure.com%2F' -and
        $Headers['X-IDENTITY-HEADER'] -eq 'test-identity-header' -and $Headers.Metadata -eq 'True'
      }
    }
    It 'rejects an unavailable Automation identity endpoint' {
      $env:IDENTITY_ENDPOINT = ''
      $threw = $false
      try { $null = Get-DeliveryToken }
      catch { $threw = $true; $_.Exception.Message | Should Match 'managed identity endpoint is unavailable' }
      $threw | Should Be $true
      Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }
    It 'rejects empty access tokens instead of attempting unauthenticated ingestion' {
      Mock Invoke-RestMethod { @{ access_token = '' } }
      $threw = $false
      try { $null = Get-DeliveryToken }
      catch { $threw = $true; $_.Exception.Message | Should Match 'no Azure Monitor access token' }
      $threw | Should Be $true
    }
  }
  Describe 'Direct daily DCR delivery' {
    BeforeEach {
      $global:ZtDirectTestRoot = Split-Path $PSScriptRoot -Parent
      $global:ZtDirectTestPosts = [Collections.Generic.List[object]]::new()
      Mock Get-DeliveryToken { ConvertTo-SecureString 'test-managed-identity-token' -AsPlainText -Force }
      Mock Invoke-RestMethod {
        $global:ZtDirectTestPosts.Add(@{ Uri = $Uri; Body = $Body; Headers = $Headers })
      }
      $dailyArguments = @{
        ConnectionPath = Join-Path $global:ZtDirectTestRoot 'examples\connection.example.json'
        GeneratorPath = Join-Path $global:ZtDirectTestRoot 'src\Send-SyntheticLogs.ps1'
      }
    }
    AfterEach {
      Remove-Variable -Name ZtDirectTestRoot,ZtDirectTestPosts -Scope Global
    }
    It 'generates and sends exactly ten fresh events to each of six DCR streams, without Storage requests' {
      $output = Invoke-DailySyntheticLogs @dailyArguments
      $global:ZtDirectTestPosts.Count | Should Be 6
      @($output | Where-Object { $_ -like 'SENT *' }).Count | Should Be 6
      $receipts = @($output | Where-Object { $_ -like 'BATCH *' } | ForEach-Object { $_.Substring(6) | ConvertFrom-Json })
      $receipts.Count | Should Be 6
      $ids = @()
      foreach ($post in $global:ZtDirectTestPosts) {
        $post.Uri | Should Match '^https://.*\.ingest\.monitor\.azure\.com/dataCollectionRules/'
        ($post.Body.Length -le 1MB) | Should Be $true
        $events = [Text.Encoding]::UTF8.GetString($post.Body) | ConvertFrom-Json
        $events.Count | Should Be 10
        foreach ($event in $events) {
          $event.IsSynthetic | Should Be $true
          $ids += $event.EventId
        }
      }
      @($ids | Select-Object -Unique).Count | Should Be 60
      foreach ($receipt in $receipts) {
        $receipt.Count | Should Be 10
        $receipt.EventIds.Count | Should Be 10
        foreach ($id in $receipt.EventIds) { ($ids -contains $id) | Should Be $true }
      }
      Assert-MockCalled Get-DeliveryToken -Times 6 -Exactly -Scope It
    }
    It 'sends sixty additional events with new identifiers on every rerun' {
      $null = Invoke-DailySyntheticLogs @dailyArguments
      $null = Invoke-DailySyntheticLogs @dailyArguments
      $global:ZtDirectTestPosts.Count | Should Be 12
      $ids = @(
        foreach ($post in $global:ZtDirectTestPosts) {
          $events = [Text.Encoding]::UTF8.GetString($post.Body) | ConvertFrom-Json
          $events | ForEach-Object { $_.EventId }
        }
      )
      $ids.Count | Should Be 120
      @($ids | Select-Object -Unique).Count | Should Be 120
    }
    It 'reports DCR failures, continues other tables, and performs no automatic replay' {
      Mock Invoke-RestMethod {
        if ($Uri -match 'ZeroTrustIdentity') { throw 'Simulated DCR HTTP 403' }
        $global:ZtDirectTestPosts.Add(@{ Uri = $Uri; Body = $Body })
      }
      $threw = $false
      try { $null = Invoke-DailySyntheticLogs @dailyArguments 2>$null }
      catch { $threw = $true; $_.Exception.Message | Should Match 'rerunning sends fresh events' }
      $threw | Should Be $true
      $global:ZtDirectTestPosts.Count | Should Be 5
      Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter { $Uri -match 'ZeroTrustIdentity' }
    }
    It 'does not post when managed identity authentication fails' {
      Mock Get-DeliveryToken { throw 'Managed identity unavailable' }
      $threw = $false
      try { $null = Invoke-DailySyntheticLogs @dailyArguments 2>$null }
      catch { $threw = $true }
      $threw | Should Be $true
      Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }
    It 'rejects duplicate event families before sending' {
      $threw = $false
      try { $null = Invoke-DailySyntheticLogs @dailyArguments -EventTypes ZeroTrustIdentity,ZeroTrustIdentity }
      catch { $threw = $true }
      $threw | Should Be $true
      Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }
  }
}
