$syntheticLogGeneratorPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Send-SyntheticLogs.ps1'
if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
  function Get-AzAccessToken {
    [CmdletBinding()]
    param([string]$ResourceUrl, [string]$TenantId)
    throw 'This test command must be mocked; no Azure login is performed.'
  }
}

Describe 'Synthetic log generation' {
  It 'generates all built-in families with typed markers and recent timestamps' {
    foreach ($family in @('Iboss', 'SigninLogs', 'AuditLogs', 'DeviceEvents',
        'DeviceNetworkEvents', 'SecurityEvent', 'AzureActivity', 'OfficeActivity', 'SecurityAlert',
        'ZeroTrustIdentity', 'ZeroTrustDevices', 'ZeroTrustApplications', 'ZeroTrustData',
        'ZeroTrustInfrastructure', 'ZeroTrustNetworks')) {
      $json = & $syntheticLogGeneratorPath -EventType $family -Count 3 -Preview
      $json.TrimStart().StartsWith('[') | Should Be $true
      $events = $json | ConvertFrom-Json
      $events.Count | Should Be 3
      foreach ($event in $events) {
        $event.IsSynthetic | Should Be $true
        $event.SyntheticSource | Should Be $family
        (([datetime]$event.TimeGenerated).ToUniversalTime() -gt [datetime]::UtcNow.AddHours(-1).AddSeconds(-5)) | Should Be $true
        (([datetime]$event.TimeGenerated).ToUniversalTime() -le [datetime]::UtcNow) | Should Be $true
      }
      $events[2].Sequence | Should Be 3
    }
  }

  It 'generates all three Zero Trust scenarios with consistent signals and stable field types' {
    foreach ($pillar in @('Identity', 'Devices', 'Applications', 'Data', 'Infrastructure', 'Networks')) {
      $events = & $syntheticLogGeneratorPath -EventType "ZeroTrust$pillar" -Count 10 -Preview | ConvertFrom-Json
      $events.Count | Should Be 10
      @($events | Where-Object { $_.Decision -eq 'Allow' }).Count | Should Be 4
      @($events | Where-Object { $_.Decision -eq 'Block' }).Count | Should Be 3
      @($events | Where-Object { $_.Decision -eq 'RequireRemediation' }).Count | Should Be 3
      $schema = ($events[0].PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value.GetType().Name)" }) -join ','
      foreach ($event in $events) {
        $event.Pillar | Should Be $pillar
        $event.Framework | Should Be 'Microsoft Zero Trust'
        $event.EvaluationMode | Should Be 'SyntheticSimulation'
        $event.SourceIP | Should Match '^192\.0\.2\.'
        (($event.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value.GetType().Name)" }) -join ',') | Should Be $schema
        switch ($event.Decision) {
          'Allow' {
            $event.RiskLevel | Should Be 'Low'
            ($event.RiskScore -ge 0 -and $event.RiskScore -lt 30) | Should Be $true
          }
          'Block' {
            $event.RiskLevel | Should Be 'High'
            ($event.RiskScore -ge 70 -and $event.RiskScore -le 100) | Should Be $true
          }
          'RequireRemediation' {
            $event.RiskLevel | Should Be 'Medium'
            ($event.RiskScore -ge 30 -and $event.RiskScore -lt 70) | Should Be $true
          }
        }
        switch ($pillar) {
          'Identity' { $event.MfaSatisfied | Should Be ($event.Decision -eq 'Allow') }
          'Devices' { $event.IsCompliant | Should Be ($event.Decision -eq 'Allow') }
          'Applications' { $event.IsSanctioned | Should Be ($event.Decision -ne 'Block') }
          'Data' { $event.IsEncrypted | Should Be ($event.Decision -eq 'Allow') }
          'Infrastructure' { $event.JitAccessApproved | Should Be ($event.Decision -eq 'Allow') }
          'Networks' { $event.SegmentPolicyMatched | Should Be ($event.Decision -ne 'Block') }
        }
      }
    }
  }

  It 'keeps a single record in a JSON array and preserves the default iboss shape' {
    $json = & $syntheticLogGeneratorPath -Count 1 -Preview
    $json.TrimStart().StartsWith('[') | Should Be $true
    $event = ($json | ConvertFrom-Json)[0]
    $event.Vendor | Should Be 'iboss'
    $event.SourceIp | Should Match '^192\.0\.2\.'
    $event.IngestSource | Should Be 'Synthetic-Iboss-Generator'
  }

  It 'keeps successful and failed logon fields consistent' {
    $signins = & $syntheticLogGeneratorPath -EventType SigninLogs -Count 100 -Preview | ConvertFrom-Json
    foreach ($event in $signins) {
      $event.Status.errorCode | Should Be ([int]$event.ResultType)
      if ($event.ResultType -eq '0') { $event.ResultDescription | Should Be 'Success' }
      else { $event.ResultDescription | Should Be 'Invalid username or password.' }
    }
    $security = & $syntheticLogGeneratorPath -EventType SecurityEvent -Count 100 -Preview | ConvertFrom-Json
    foreach ($event in $security) {
      if ($event.EventID -eq 4624) { $event.Status | Should Be '0x0' }
      else {
        $event.EventID | Should Be 4625
        $event.Status | Should Be '0xc000006d'
      }
    }
  }

  It 'expands nested custom templates without executing expressions or losing literal types' {
    $path = Join-Path $TestDrive 'template.json'
    @'
{"Caller":"{{User}}","Repeat":"{{Guid}}/{{Guid}}","Ip":"{{IPAddress}}","Nested":{"Items":["{{DeviceName}}"],"Empty":[],"Null":null},"Number":42,"Flag":true,"Unicode":"caf\u00e9","Literal":"$(throw 'do not execute')","IsSynthetic":false}
'@ | Set-Content -LiteralPath $path -Encoding UTF8
    $json = & $syntheticLogGeneratorPath -EventType Custom -TemplatePath $path -UserDomain example.org -Count 2 -Preview
    $events = $json | ConvertFrom-Json
    $events[0].Caller | Should Match '@example.org$'
    $ids = $events[0].Repeat.Split('/')
    $ids[0] | Should Be $ids[1]
    ($events[0].Repeat -ne $events[1].Repeat) | Should Be $true
    $events[0].Nested.Items.Count | Should Be 1
    $events[0].Nested.Empty.Count | Should Be 0
    ($null -eq $events[0].Nested.Null) | Should Be $true
    $events[0].Number | Should Be 42
    $events[0].Flag | Should Be $true
    $events[0].IsSynthetic | Should Be $true
    $events[0].Literal | Should Be '$(throw ''do not execute'')'
  }

  It 'rejects invalid inputs rather than silently generating defaults' {
    foreach ($arguments in @(
        @{ Count = 0; Preview = $true },
        @{ EventType = 'Unknown'; Preview = $true },
        @{ EventType = 'Custom'; Preview = $true },
        @{ LogType = 'Foo_CL'; Preview = $true },
        @{ LogType = 'bad name'; Preview = $true },
        @{ WorkspaceId = 'invalid'; WorkspaceKey = 'bad' }
      )) {
      $threw = $false
      try { $null = & $syntheticLogGeneratorPath @arguments }
      catch { $threw = $true }
      $threw | Should Be $true
    }
    $path = Join-Path $TestDrive 'invalid.json'
    foreach ($content in @('[]', '{"Value":"{{Unknown}}"}', '{invalid')) {
      $content | Set-Content -LiteralPath $path
      $threw = $false
      try { $null = & $syntheticLogGeneratorPath -EventType Custom -TemplatePath $path -Preview }
      catch { $threw = $true }
      $threw | Should Be $true
    }
    $threw = $false
    try { $null = & $syntheticLogGeneratorPath -TemplatePath $path -Preview }
    catch { $threw = $true }
    $threw | Should Be $true
  }
}

    Describe 'Offline DCR ingestion contract' {
      BeforeEach {
        $global:SyntheticLogTestRequests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod {
          $global:SyntheticLogTestRequests.Add(@{
            Uri = $Uri; Headers = $Headers; Body = $Body; MaximumRedirection = $MaximumRedirection
          })
        }
        Mock Get-AzAccessToken {
          [pscustomobject]@{ Token = ConvertTo-SecureString 'az-test-token' -AsPlainText -Force }
        }
        $dcrArguments = @{
          IngestionEndpoint = 'https://synthetic.eastus-1.ingest.monitor.azure.com'
          DcrImmutableId = 'dcr-0123456789abcdef0123456789abcdef'
          StreamName = 'Custom-SyntheticSigninLogs'
          AccessToken = ConvertTo-SecureString 'provided-test-token' -AsPlainText -Force
        }
      }

      AfterEach {
        Remove-Variable -Name SyntheticLogTestRequests -Scope Global
      }

      It 'sends UTF8 arrays to the exact DCR stream using only bearer authentication' {
        & $syntheticLogGeneratorPath @dcrArguments -EventType SigninLogs -Count 5 -BatchSize 2
        $global:SyntheticLogTestRequests.Count | Should Be 3
        $total = 0
        foreach ($request in $global:SyntheticLogTestRequests) {
          $request.Uri | Should Be 'https://synthetic.eastus-1.ingest.monitor.azure.com/dataCollectionRules/dcr-0123456789abcdef0123456789abcdef/streams/Custom-SyntheticSigninLogs?api-version=2023-01-01'
          $request.Headers.Authorization | Should Be 'Bearer provided-test-token'
          $request.Headers.Count | Should Be 1
          $request.MaximumRedirection | Should Be 0
          ($request.Body -is [byte[]]) | Should Be $true
          $json = [Text.Encoding]::UTF8.GetString($request.Body)
          $json.StartsWith('[') | Should Be $true
          $records = $json | ConvertFrom-Json
          $total += $records.Count
          $records[0].IsSynthetic | Should Be $true
        }
        $total | Should Be 5
        Assert-MockCalled Get-AzAccessToken -Times 0 -Exactly -Scope It
      }

      It 'uses the specified tenant and refreshes Az.Accounts tokens for each request in every cloud' {
        $dcrArguments.Remove('AccessToken')
        foreach ($cloudCase in @(
            @{ Cloud = 'AzureCloud'; Domain = 'monitor.azure.com' },
            @{ Cloud = 'AzureUSGovernment'; Domain = 'monitor.azure.us' },
            @{ Cloud = 'AzureChinaCloud'; Domain = 'monitor.azure.cn' }
          )) {
          $dcrArguments.IngestionEndpoint = "https://synthetic.region-1.ingest.$($cloudCase.Domain)/"
          & $syntheticLogGeneratorPath @dcrArguments -Cloud $cloudCase.Cloud -Count 2 -BatchSize 1
        }
        $global:SyntheticLogTestRequests.Count | Should Be 6
        foreach ($request in $global:SyntheticLogTestRequests) {
          $request.Headers.Authorization | Should Be 'Bearer az-test-token'
        }
        Assert-MockCalled Get-AzAccessToken -Times 2 -Exactly -Scope It -ParameterFilter {
          $ResourceUrl -eq 'https://monitor.azure.com/' -and $TenantId -eq '11111111-1111-4111-8111-111111111111'
        }
        Assert-MockCalled Get-AzAccessToken -Times 2 -Exactly -Scope It -ParameterFilter {
          $ResourceUrl -eq 'https://monitor.azure.us/' -and $TenantId -eq '11111111-1111-4111-8111-111111111111'
        }
        Assert-MockCalled Get-AzAccessToken -Times 2 -Exactly -Scope It -ParameterFilter {
          $ResourceUrl -eq 'https://monitor.azure.cn/' -and $TenantId -eq '11111111-1111-4111-8111-111111111111'
        }
      }

      It 'supports string tokens from older Az.Accounts and honors a tenant override' {
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'older-az-token' } }
        $dcrArguments.Remove('AccessToken')
        & $syntheticLogGeneratorPath @dcrArguments -TenantId '44444444-4444-4444-8444-444444444444' -Count 1
        $global:SyntheticLogTestRequests[0].Headers.Authorization | Should Be 'Bearer older-az-token'
        Assert-MockCalled Get-AzAccessToken -Times 1 -Exactly -Scope It -ParameterFilter {
          $TenantId -eq '44444444-4444-4444-8444-444444444444'
        }
      }

      It 'does not authenticate or send when previewing DCR events' {
        $dcrArguments.Remove('AccessToken')
        $json = & $syntheticLogGeneratorPath @dcrArguments -EventType SigninLogs -Count 1 -Preview
        ($json | ConvertFrom-Json)[0].SyntheticSource | Should Be 'SigninLogs'
        Assert-MockCalled Get-AzAccessToken -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
      }

      It 'selects the correct stream from a non-secret connection file' {
        $path = Join-Path $TestDrive 'connection.json'
        @{
          TenantId = '11111111-1111-4111-8111-111111111111'
          Cloud = 'AzureCloud'
          IngestionEndpoint = $dcrArguments.IngestionEndpoint
          DcrImmutableId = $dcrArguments.DcrImmutableId
          Streams = @{ DeviceEvents = @{ StreamName = 'Custom-SyntheticDcrDeviceEvents'; TableName = 'SyntheticDcrDeviceEvents_CL' } }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
        & $syntheticLogGeneratorPath -DcrConfigPath $path -EventType DeviceEvents -Count 1 -AccessToken $dcrArguments.AccessToken
        $global:SyntheticLogTestRequests[0].Uri | Should Match '/streams/Custom-SyntheticDcrDeviceEvents\?'
        foreach ($invalidArguments in @(
            @{ EventType = 'SecurityAlert' },
            @{ EventType = 'DeviceEvents'; Cloud = 'AzureUSGovernment' }
          )) {
          $threw = $false
          try { $null = & $syntheticLogGeneratorPath -DcrConfigPath $path @invalidArguments -Preview }
          catch { $threw = $true }
          $threw | Should Be $true
        }
      }

      It 'splits large batches by actual UTF8 size without losing or duplicating events' {
        $path = Join-Path $TestDrive 'split.json'
        $template = [ordered]@{}
        for ($i = 0; $i -lt 18; $i++) { $template["Field$i"] = ([string][char]0xe9) * 16000 }
        ConvertTo-Json -InputObject $template | Set-Content -LiteralPath $path -Encoding UTF8
        & $syntheticLogGeneratorPath @dcrArguments -EventType Custom -TemplatePath $path -Count 3 -BatchSize 3
        $global:SyntheticLogTestRequests.Count | Should Be 3
        $sequences = @()
        foreach ($request in $global:SyntheticLogTestRequests) {
          ($request.Body.Length -le 1MB) | Should Be $true
          $records = [Text.Encoding]::UTF8.GetString($request.Body) | ConvertFrom-Json
          $records.Count | Should Be 1
          $records[0].Field0.Length | Should Be 16000
          $sequences += $records[0].Sequence
        }
        ($sequences -join ',') | Should Be '1,2,3'
      }

      It 'rejects a single oversized event before authentication or any writes' {
        $path = Join-Path $TestDrive 'oversized-dcr.json'
        ('{"Message":"' + ('x' * 1MB) + '"}') | Set-Content -LiteralPath $path -Encoding UTF8
        { & $syntheticLogGeneratorPath @dcrArguments -EventType Custom -TemplatePath $path -Count 1 } |
          Should Throw 'single event exceeds the 1 MB'
        Assert-MockCalled Get-AzAccessToken -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
      }

      It 'rejects invalid or mixed configuration before making requests' {
        foreach ($invalid in @(
            @{ IngestionEndpoint = 'http://synthetic.region.ingest.monitor.azure.com' },
            @{ IngestionEndpoint = 'https://untrusted.example.com' },
            @{ IngestionEndpoint = 'https://synthetic.region.ingest.monitor.azure.us' },
            @{ IngestionEndpoint = 'https://synthetic.region.ingest.monitor.azure.com/path' },
            @{ IngestionEndpoint = 'https://synthetic.region.ingest.monitor.azure.com/?x=1' },
            @{ IngestionEndpoint = 'https://user@synthetic.region.ingest.monitor.azure.com' },
            @{ DcrImmutableId = '/subscriptions/example/providers/Microsoft.Insights/dataCollectionRules/test' },
            @{ DcrImmutableId = '' },
            @{ StreamName = '' },
            @{ StreamName = 'bad/stream' },
            @{ LogType = 'IgnoredDestination' },
            @{ WorkspaceKey = 'not-a-key' },
            @{ WorkspaceId = '33333333-3333-4333-8333-333333333333' }
          )) {
          $arguments = $dcrArguments.Clone()
          foreach ($name in $invalid.Keys) { $arguments[$name] = $invalid[$name] }
          $threw = $false
          try { $null = & $syntheticLogGeneratorPath @arguments -Count 1 }
          catch { $threw = $true }
          $threw | Should Be $true
        }
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
      }

      It 'reports auth failures and does not fall back to legacy ingestion' {
        $dcrArguments.Remove('AccessToken')
        Mock Get-AzAccessToken { throw 'Simulated authentication failure' }
        { & $syntheticLogGeneratorPath @dcrArguments -Count 1 } | Should Throw 'after 0 accepted records'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
      }

      It 'rejects empty tokens without sending a request' {
        $dcrArguments.AccessToken = [System.Security.SecureString]::new()
        { & $syntheticLogGeneratorPath @dcrArguments -Count 1 } | Should Throw 'No access token'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
      }

      It 'stops on DCR errors and reports only previously accepted records' {
        Mock Invoke-RestMethod {
          if ($global:SyntheticLogTestRequests.Count -eq 1) { throw 'Simulated 429 throttling' }
          $global:SyntheticLogTestRequests.Add(@{ Body = $Body })
        }
        { & $syntheticLogGeneratorPath @dcrArguments -Count 5 -BatchSize 2 } | Should Throw 'after 2 accepted records'
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
      }
    }
Describe 'Offline ingestion contract' {
  BeforeEach {
    $global:SyntheticLogTestRequests = [System.Collections.Generic.List[object]]::new()
    Mock Invoke-RestMethod {
      $global:SyntheticLogTestRequests.Add(@{ Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = $ContentType })
    }
    $workspace = '33333333-3333-4333-8333-333333333333'
    $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('test-only-key'))
  }

  AfterEach {
    Remove-Variable -Name SyntheticLogTestRequests -Scope Global
  }

  It 'batches records as UTF8 JSON arrays and signs the exact transmitted bytes' {
    $path = Join-Path $TestDrive 'unicode.json'
    '{"Message":"caf\u00e9"}' | Set-Content -LiteralPath $path
    & $syntheticLogGeneratorPath -WorkspaceId $workspace -WorkspaceKey $key -EventType Custom `
      -TemplatePath $path -Count 5 -BatchSize 2 -Cloud AzureUSGovernment -LogType Lab -WarningAction SilentlyContinue
    $global:SyntheticLogTestRequests.Count | Should Be 3
    $total = 0
    foreach ($request in $global:SyntheticLogTestRequests) {
      ($request.Body -is [byte[]]) | Should Be $true
      $json = [Text.Encoding]::UTF8.GetString($request.Body)
      $json.StartsWith('[') | Should Be $true
      $records = $json | ConvertFrom-Json
      $total += $records.Count
      $records[0].Message | Should Be ("caf" + [char]0xe9)
      $request.Uri | Should Match '\.ods\.opinsights\.azure\.us/'
      $request.Headers['Log-Type'] | Should Be 'Lab'
      $request.Headers['time-generated-field'] | Should Be 'TimeGenerated'
      $toSign = "POST`n$($request.Body.Length)`napplication/json`nx-ms-date:$($request.Headers['x-ms-date'])`n/api/logs"
      $hmac = [Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($key))
      try { $hash = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($toSign))) }
      finally { $hmac.Dispose() }
      $request.Headers.Authorization | Should Be "SharedKey ${workspace}:$hash"
    }
    $total | Should Be 5
    ([Text.Encoding]::UTF8.GetString($global:SyntheticLogTestRequests[2].Body) | ConvertFrom-Json).Count | Should Be 1
  }

  It 'makes no network request during preview' {
    $null = & $syntheticLogGeneratorPath -EventType AzureActivity -Count 1 -Preview
    Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
  }

  It 'preserves the old default table and selects the public cloud endpoint' {
    & $syntheticLogGeneratorPath -WorkspaceId $workspace -WorkspaceKey $key -Count 1 -WarningAction SilentlyContinue
    $global:SyntheticLogTestRequests[0].Headers['Log-Type'] | Should Be 'IbossSynthetic'
    $global:SyntheticLogTestRequests[0].Uri | Should Match '\.ods\.opinsights\.azure\.com/'
  }

  It 'selects the China endpoint and the Microsoft template destination' {
    & $syntheticLogGeneratorPath -WorkspaceId $workspace -WorkspaceKey $key -EventType SigninLogs `
      -Cloud AzureChinaCloud -Count 1 -WarningAction SilentlyContinue
    $global:SyntheticLogTestRequests[0].Headers['Log-Type'] | Should Be 'SyntheticSigninLogs'
    $global:SyntheticLogTestRequests[0].Uri | Should Match '\.ods\.opinsights\.azure\.cn/'
  }

  It 'rejects payloads above the exact 30 MB threshold before any request' {
    $path = Join-Path $TestDrive 'large.json'
    ('{"Message":"' + ('x' * (30MB + 1)) + '"}') | Set-Content -LiteralPath $path -Encoding UTF8
    { & $syntheticLogGeneratorPath -WorkspaceId $workspace -WorkspaceKey $key -EventType Custom `
        -TemplatePath $path -Count 1 -WarningAction SilentlyContinue } | Should Throw '30 MB'
    Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
  }

  It 'stops and reports prior accepted records when a later batch fails' {
    Mock Invoke-RestMethod {
      if ($global:SyntheticLogTestRequests.Count -eq 1) { throw 'Simulated ingestion failure' }
      $global:SyntheticLogTestRequests.Add(@{ Body = $Body })
    }
    { & $syntheticLogGeneratorPath -WorkspaceId $workspace -WorkspaceKey $key -Count 5 -BatchSize 2 -WarningAction SilentlyContinue } |
      Should Throw 'after 2 accepted records'
    Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
  }
}
