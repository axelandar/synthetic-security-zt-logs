# Superseded: private-network daily delivery plan

The original daily runbook used Blob-backed delivery state. Cloud jobs could
not access that state because organization policy disables public Storage
networking. A private endpoint and Hybrid Worker were proposed, but not deployed.

The approved replacement generates fresh events on every run and sends directly
to the DCR from cloud Automation. It does not access Storage or require a Hybrid
Worker. Manual reruns intentionally add another sixty synthetic events.

This replaces the former private-network approval plan; do not provision its
worker or network dependencies. Existing unused Storage/data is retained, and
no network policy, exemption, or public-network setting is changed.

See the current [README](../README.md) and [operations guide](operations.md).
