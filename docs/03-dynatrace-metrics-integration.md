# Dynatrace Metrics Integration for Consul

This document describes how to ingest Consul metrics into Dynatrace using both the DogStatsD push path and the Prometheus pull path. Both mechanisms are available to Dynatrace OneAgent and ActiveGate deployments on OpenShift.

## Integration Architecture

```
                  ┌─────────────────────────────────────────┐
                  │  Consul Server / Dataplane Pod           │
                  │                                          │
                  │  consul agent  ──DogStatsD (UDP)──────► │──┐
                  │                                          │  │
                  │  /v1/agent/metrics?format=prometheus  ◄──│  │
                  └─────────────────────────────────────────┘  │
                            ▲                                    │
                  Prometheus │ scrape                            │ UDP :8125
                            │                                    ▼
              ┌─────────────────────────┐      ┌──────────────────────────┐
              │  Dynatrace ActiveGate   │      │  Dynatrace OneAgent       │
              │  (Prometheus extension) │      │  (DogStatsD listener)     │
              └────────────┬────────────┘      └──────────────┬────────────┘
                           │                                    │
                           ▼                                    ▼
                  ┌──────────────────────────────────────────────┐
                  │          Dynatrace Platform                   │
                  │  Metrics  │  Dashboards  │  Anomaly Detection │
                  └──────────────────────────────────────────────┘
```

---

## Path 1: DogStatsD via Dynatrace OneAgent

Dynatrace OneAgent includes a built-in DogStatsD listener. When enabled, OneAgent accepts UDP metrics on port 8125 and automatically maps them to Dynatrace custom metrics with the host entity as the topology anchor.

### Enable DogStatsD in OneAgent

In the Dynatrace UI: **Settings → Processes and containers → StatsD**.

Or via the Dynatrace API — set the `statsd.enabled` OneAgent feature flag:

```json
PUT /api/v1/onAgents/{agentId}/features
{
  "features": [
    { "type": "statsd", "enabled": true }
  ]
}
```

OneAgent listens on `localhost:8125` (UDP) on each OpenShift node. Consul pods send their DogStatsD metrics to `$(HOST_IP):8125` (using the Kubernetes downward API for the node IP).

### Metric Naming

DogStatsD metrics arrive in Dynatrace as `ext:<metric_name>`, where `<metric_name>` is the metric emitted by Consul. For example:

| Consul metric (DogStatsD) | Dynatrace metric key |
|---|---|
| `consul.raft.commitTime` | `ext.consul.raft.commitTime` |
| `consul.autopilot.healthy` | `ext.consul.autopilot.healthy` |
| `consul.runtime.alloc_bytes` | `ext.consul.runtime.alloc_bytes` |

Tags sent by the Consul agent (e.g., `consul_datacenter:dc1`, `consul_role:server`) are preserved as Dynatrace metric dimensions.

---

## Path 2: Prometheus via Dynatrace ActiveGate Extension

The Dynatrace Prometheus scraper extension allows ActiveGate to pull metrics from Consul's `/v1/agent/metrics?format=prometheus` endpoint. This is the preferred approach for OpenShift environments that already use a pull-based observability pattern.

### Prerequisites

- Dynatrace ActiveGate deployed in the OpenShift cluster (or accessible externally to the cluster network)
- Consul HTTP API accessible from the ActiveGate pod (direct pod IP or via a Kubernetes Service)
- A Consul ACL token with `agent:read` policy (see [docs/02-consul-telemetry-configuration.md](./02-consul-telemetry-configuration.md))

### Configure a Prometheus Scrape Target

Create a Dynatrace Extension 2.0 that defines the Prometheus scrape target. A ready-to-use extension definition is provided at [`configs/dynatrace-extension/extension.yaml`](../configs/dynatrace-extension/extension.yaml).

The extension scrapes:

```
http://<consul-pod-ip>:8500/v1/agent/metrics?format=prometheus
```

With the HTTP header:

```
X-Consul-Token: <acl-token>
```

### Deploying the Extension

1. Package and sign the extension:

   ```bash
   dt-sdk build
   dt-sdk sign --target consul-monitoring.zip \
     --certificate <your-cert.pem> \
     --privateKey <your-key.pem>
   ```

2. Upload via the Dynatrace API:

   ```bash
   curl -X POST "https://<your-tenant>.live.dynatrace.com/api/v2/extensions" \
     -H "Authorization: Api-Token <token>" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @consul-monitoring.zip
   ```

3. Activate the extension and configure the monitoring configuration (endpoint URL, ACL token as a credential) in the Dynatrace UI under **Observe and Explore → Metrics → Extensions**.

### Storing ACL Token Credentials Securely

Never hardcode the Consul ACL token in the extension configuration. Use Dynatrace credential vault:

```bash
curl -X POST "https://<tenant>.live.dynatrace.com/api/v2/credentials" \
  -H "Authorization: Api-Token <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "consul-metrics-token",
    "type": "PUBLIC_CERTIFICATE",
    "password": "<consul-acl-token>"
  }'
```

Reference the credential by its ID in the extension monitoring configuration.

---

## Metric Dimensions

When ingesting Consul metrics into Dynatrace, apply the following standard dimensions to all metrics to support filtering and dashboarding:

| Dimension Key | Value Source | Example |
|---|---|---|
| `consul.datacenter` | DogStatsD tag or Prometheus label | `dc1` |
| `consul.role` | DogStatsD tag or Prometheus label | `server` or `client` |
| `dt.entity.host` | Resolved by Dynatrace OneAgent automatically | `HOST-abc123` |

For Prometheus-ingested metrics, add a `consul_role` label to the scrape job if you have separate scrape targets for servers vs. clients.

---

## Verifying Metric Ingestion

After enabling telemetry, confirm metrics are arriving in Dynatrace:

### Via DogStatsD

1. In the Dynatrace UI, navigate to **Observe and Explore → Metrics**.
2. Search for `ext.consul`.
3. You should see metrics like `ext.consul.raft.commitTime`, `ext.consul.autopilot.healthy`, etc.

### Via Prometheus Extension

1. Navigate to the extension monitoring configuration.
2. Check the "Last ingest" timestamp and status.
3. Run a metric query in the Dynatrace UI:

   ```
   consul_raft_commitTime
   ```

### Via Metrics API (DQL)

Using Dynatrace Query Language (DQL) in a notebook or dashboard tile:

```dql
timeseries consul_leader_last_contact = avg(ext.consul.raft.leader.lastContact),
  by: { consul.datacenter, consul.role }
```

---

## Consul Dataplane and Envoy Sidecar Metrics

For `consul-dataplane` sidecars, the merged Prometheus endpoint is at the pod IP on port 20200 (when `envoy_prometheus_bind_addr` is configured in `proxy-defaults`). Configure a separate scrape target for this:

```
http://<pod-ip>:20200/metrics
```

This endpoint returns merged metrics from three sources:
- `consul_dataplane.*` — dataplane connectivity and server connection health
- `envoy_cluster_*` — per-upstream-service L7 request metrics (rate, error rate, latency, circuit breaker state)
- `envoy_http_*` — per-listener inbound request metrics

**Annotate application pods** to enable Dynatrace scraping of the port 20200 endpoint:

```yaml
annotations:
  metrics.dynatrace.com/scrape: "true"
  metrics.dynatrace.com/port: "20200"
  metrics.dynatrace.com/path: "/metrics"
```

See [docs/05-key-metrics-and-alerts.md](./05-key-metrics-and-alerts.md) for `consul_dataplane.*` alert thresholds and [docs/07-application-observability.md](./07-application-observability.md) for the full L7 metrics and distributed tracing setup.
