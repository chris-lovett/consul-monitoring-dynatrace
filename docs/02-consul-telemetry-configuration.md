# Configuring Consul Telemetry

Consul agents emit metrics for all internal subsystems. Before Dynatrace can ingest those metrics, you must configure the Consul agent to export them. Two export mechanisms are supported for Dynatrace: **DogStatsD** (push) and **Prometheus** (pull).

## Agent Telemetry Configuration Reference

Add a `telemetry` stanza to every Consul agent configuration file (both server and client agents).

### Option A: DogStatsD (Recommended for Dynatrace OneAgent)

The Consul agent pushes metrics to a DogStatsD listener every **10 seconds**. Dynatrace OneAgent includes a built-in DogStatsD listener on UDP port 8125 that can receive these metrics directly.

```hcl
telemetry {
  # Send metrics to Dynatrace OneAgent's DogStatsD listener
  dogstatsd_addr   = "localhost:8125"
  dogstatsd_tags   = ["consul_datacenter:dc1", "consul_role:server"]

  # Do not prefix gauge metrics with the hostname (Dynatrace uses its own
  # host-entity dimension for that)
  disable_hostname = true

  # How long to retain in-memory metrics (set to 0 to rely solely on the
  # external store and reduce memory overhead)
  retention_time = "0s"

  # Enable prefixing metric names with the Consul filter prefix — leave
  # empty to receive all metrics (recommended; you can filter in Dynatrace)
  metrics_prefix = "consul"
}
```

> **OpenShift note:** When Consul runs in a pod, `localhost:8125` resolves to the DogStatsD listener on the Dynatrace OneAgent that is injected into the same node. If OneAgent runs as a DaemonSet (the standard deployment), UDP traffic from any pod on that node is accepted on port 8125.

### Option B: Prometheus (Recommended for scrape-based pipelines)

The Consul agent exposes a Prometheus-format metrics endpoint at `/v1/agent/metrics?format=prometheus`. Enable this in the agent configuration:

```hcl
telemetry {
  # Expose a Prometheus metrics endpoint (Consul does not start an HTTP
  # server for this — it is served through the existing HTTP API)
  prometheus_retention_time = "60s"

  disable_hostname  = true
  metrics_prefix    = "consul"
}
```

Then configure your Dynatrace ActiveGate to scrape the endpoint (see [docs/03-dynatrace-metrics-integration.md](./03-dynatrace-metrics-integration.md)).

The metrics endpoint requires an ACL token with `agent:read` permission. Example request:

```bash
curl -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/metrics?format=prometheus
```

### Using Both Together

You can enable both DogStatsD and Prometheus simultaneously. This gives you low-latency push metrics via DogStatsD and a consistent pull baseline for scrape-based dashboards:

```hcl
telemetry {
  dogstatsd_addr            = "localhost:8125"
  dogstatsd_tags            = ["consul_datacenter:dc1"]
  prometheus_retention_time = "60s"
  disable_hostname          = true
  metrics_prefix            = "consul"
}
```

## Applying the Configuration

The telemetry stanza can be placed in any `.hcl` or `.json` file in the Consul agent's configuration directory (default: `/etc/consul.d/`). On OpenShift, the recommended approach is to add a ConfigMap for the telemetry stanza and mount it into the Consul pod:

```yaml
# telemetry-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: consul-telemetry-config
  namespace: consul
data:
  telemetry.hcl: |
    telemetry {
      dogstatsd_addr            = "$(HOST_IP):8125"
      dogstatsd_tags            = ["consul_datacenter:dc1", "consul_role:server"]
      prometheus_retention_time = "60s"
      disable_hostname          = true
      metrics_prefix            = "consul"
    }
```

> `HOST_IP` is the Kubernetes downward API environment variable that resolves to the node IP. For Dynatrace OneAgent in DaemonSet mode, this ensures the DogStatsD metrics are sent to the agent on the same node.

Mount the ConfigMap in your `values.yaml` for the Consul Helm chart:

```yaml
server:
  extraVolumes:
    - type: configMap
      name: consul-telemetry-config
      load: true
      items:
        - key: telemetry.hcl
          path: telemetry.hcl
```

A ready-to-use HCL configuration file is available at [`configs/consul-telemetry-agent.hcl`](../configs/consul-telemetry-agent.hcl).

## Dataplane Telemetry

`consul-dataplane` (the lightweight sidecar component that replaces client agents on OpenShift/Kubernetes) emits its own set of metrics. These are configured separately via the Envoy proxy-defaults configuration entry or the proxy service definition — not through the Consul agent telemetry stanza.

To enable `consul-dataplane` metrics with Prometheus:

```hcl
# proxy-defaults config entry — apply to the cluster with `consul config write`
Kind = "proxy-defaults"
Name = "global"

Config {
  envoy_prometheus_bind_addr = "0.0.0.0:20200"
}
```

When this is set, `consul-dataplane` merges metrics from:
- `consul-dataplane` itself
- The Envoy process it manages
- (Optionally) your service instance

All three are exposed on a single Prometheus endpoint at the pod IP:20200. Dynatrace ActiveGate can scrape this endpoint with a PodMonitor or custom extension scrape config.

Key `consul_dataplane.*` metrics:

| Metric | Description | Type |
|---|---|---|
| `consul_dataplane.connected` | 1 if connected to a Consul server, 0 otherwise | Gauge |
| `consul_dataplane.connect_duration` | Time spent connecting to a Consul server | Timer (ms) |
| `consul_dataplane.connection_errors` | gRPC stream errors (labeled by status code) | Gauge |
| `consul_dataplane.envoy_connected` | 1 if Envoy is connected and receiving xDS updates | Gauge |
| `consul_dataplane.login_duration` | Time spent logging in to ACL auth method | Timer (ms) |
| `consul_dataplane.discover_servers_duration` | Time spent discovering Consul server IPs | Timer (ms) |

## Telemetry Intervals

| Export Method | Collection Interval |
|---|---|
| DogStatsD | 10 seconds |
| StatsD | 10 seconds |
| Prometheus scrape | 60 seconds (configurable via `prometheus_retention_time`) |

## Disabling Hostname Prefix

By default, Consul prefixes gauge metric names with the agent hostname (e.g., `consul.<hostname>.server.isLeader`). When sending to Dynatrace, this creates separate metric series per host and prevents cross-host aggregation. **Always set `disable_hostname = true`** and let Dynatrace handle host dimensioning through its entity model.

## ACL Permissions for Metrics

If ACLs are enabled (required for Consul Enterprise), the token used to query the metrics API must have the following policy:

```hcl
# consul-metrics-policy.hcl
agent_prefix "" {
  policy = "read"
}
```

Apply the policy and create a token:

```bash
consul acl policy create -name "metrics-read" -rules @consul-metrics-policy.hcl
consul acl token create -description "Dynatrace metrics scraper" \
  -policy-name "metrics-read"
```
