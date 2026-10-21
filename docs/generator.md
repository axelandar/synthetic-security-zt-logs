# Interactive generator

The original 15-family generator is available independently of the daily service.
It supports preview, DCR bearer-token ingestion, custom templates, batching, and
legacy workspace-key compatibility.

## Preview or export

```powershell
.\src\Send-SyntheticLogs.ps1 -EventType DeviceNetworkEvents -Count 5 -Preview
.\src\Send-SyntheticLogs.ps1 -EventType ZeroTrustData -Count 10 -Preview |
  Set-Content .\.local\preview.json -Encoding UTF8
```

Preview requires no credentials and makes no network requests.

## Send through an existing DCR

```powershell
Connect-AzAccount -Tenant '<tenant-id>'
.\src\Send-SyntheticLogs.ps1 -DcrConfigPath .\.local\connection.json `
  -EventType ZeroTrustDevices -Count 10
```

Alternatively supply `-IngestionEndpoint`, `-DcrImmutableId`, and `-StreamName`.
Use an authenticated Az.Accounts session or provide `-AccessToken` as a
SecureString. Supplied tokens are not automatically refreshed.

The exact input stream must accept that family's schema. A stream does not
automatically adapt to all templates, and `-LogType` cannot redirect DCR routing.
Nested objects/arrays are dynamic columns. Time fields have datetime types.
`DeviceEvents.AdditionalFields` is parsed from a JSON string to dynamic by the
deployment's transformation.

## Custom JSON shape

```json
{
  "OperationName": "SyntheticOperation",
  "CorrelationId": "{{Guid}}",
  "Caller": "{{User}}",
  "IPAddress": "{{IPAddress}}",
  "Details": { "Device": "{{DeviceName}}", "At": "{{Timestamp}}" },
  "Tags": ["synthetic", "{{TenantId}}"],
  "DurationMs": 42,
  "Success": true
}
```

Save one JSON object (not an array), then:

```powershell
.\src\Send-SyntheticLogs.ps1 -EventType Custom `
  -TemplatePath .\.local\template.json -Count 10 -Preview
```

String tokens: `{{Timestamp}}`, `{{Guid}}`, `{{User}}`, `{{UserId}}`,
`{{IPAddress}}`, `{{DeviceName}}`, `{{TenantId}}`, `{{SubscriptionId}}`,
`{{Sequence}}`. Repeated tokens share their value within an event. Tokens expand
only in string values, never property names; unknown tokens fail. They are plain
substitutions, not executable expressions. Token values remain strings.
Numeric/boolean/null literals retain their types.

The generator owns `TimeGenerated`, `TenantId`, `Sequence`, `IsSynthetic`,
`SyntheticSource`, and `IngestSource`, overriding template values.

Sending custom templates requires provisioning a matching table/DCR stream
separately. The bundled deployment intentionally defines only the 15 built-ins.
The daily schedule intentionally covers only the six Zero Trust families.

## Limits and failure behavior

- `-Count`: 1-100000, default 20.
- `-BatchSize`: 1-1000, default 500.
- `-LookbackMinutes`: 1-1440, default 60.
- DCR batches split on actual UTF-8 size at 1 MB; a single oversized event fails.
- All payloads are built before ingestion. HTTP failure stops sending; earlier
  batches are not rolled back, and manually rerunning can duplicate them.
- The daily service generates and sends ten fresh events per pillar on every run,
  including reruns. It uses the same sender with managed identity authentication.
  `-PassThru` returns accepted event objects after all requests succeed, enabling
  the daily service to write exact event-ID receipts.
- Other service field-size, timestamp, and throughput limits still apply.
- Default users/devices/subscription IDs are fictional. The tenant value should
  come from your connection settings.

## Sovereign clouds and legacy support

The sender supports `-Cloud AzureUSGovernment` or `AzureChinaCloud` with the
matching authentication environment, monitor audience, and ingestion endpoint.
The scheduled infrastructure deployment currently supports Azure public cloud only.

The old workspace-key path remains available with `-WorkspaceId`, `-WorkspaceKey`,
and optionally `-LogType` (prefix without `_CL`). It uses the unsupported HTTP
Data Collector API and is not recommended for new workloads. Legacy columns may
have `_s`/`_b` suffixes; DCR typed columns do not.
