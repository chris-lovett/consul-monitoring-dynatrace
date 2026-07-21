# Consul Enterprise Monitoring with Dynatrace

Consul's role as the service mesh control plane makes it foundational to everything running on top of it — service discovery, health-based routing, mTLS certificate issuance, and access control all flow through the Consul server cluster. Gaps in Consul observability translate directly into gaps in your ability to detect and respond to degraded mesh behavior before it surfaces as a user-facing incident.

This repository covers the full instrumentation path for Consul Enterprise on Red Hat OpenShift with Dynatrace as the observability backend: from enabling agent-level telemetry and structuring log output, through ingesting metrics and logs into Dynatrace, to defining the alert thresholds that matter operationally. It bridges three sets of documentation that operators typically have to reconcile independently — Consul's telemetry reference, the Dynatrace Extensions 2.0 model, and OpenShift's networking and security constraints — and consolidates them into a single, deployable baseline.

This repository covers two observability layers. The first is Consul control plane and dataplane health: Raft consensus stability, write performance, TLS certificate and Enterprise license expiration, `consul-dataplane` sidecar connectivity, host resource pressure, and the log events most likely to indicate a cluster problem before metrics catch up. The second is application-level service mesh observability: Envoy L7 traffic metrics (request rate, error rate, latency per upstream service), proxy access logs with per-request response flag detail, and distributed tracing via OpenTelemetry through to Dynatrace.

## What This Covers

| Topic | Document |
|---|---|
| Architecture overview and component map | [docs/01-architecture-overview.md](docs/01-architecture-overview.md) |
| Configuring Consul telemetry (DogStatsD / Prometheus) | [docs/02-consul-telemetry-configuration.md](docs/02-consul-telemetry-configuration.md) |
| Ingesting Consul metrics into Dynatrace | [docs/03-dynatrace-metrics-integration.md](docs/03-dynatrace-metrics-integration.md) |
| Ingesting Consul logs into Dynatrace | [docs/04-dynatrace-log-monitoring.md](docs/04-dynatrace-log-monitoring.md) |
| Key metrics, thresholds, and alert definitions | [docs/05-key-metrics-and-alerts.md](docs/05-key-metrics-and-alerts.md) |
| OpenShift-specific considerations | [docs/06-openshift-considerations.md](docs/06-openshift-considerations.md) |
| Envoy L7 metrics, access logs, and distributed tracing | [docs/07-application-observability.md](docs/07-application-observability.md) |

## Configuration Artifacts

| Artifact | Purpose |
|---|---|
| [`configs/consul-telemetry-agent.hcl`](configs/consul-telemetry-agent.hcl) | Consul agent telemetry stanza (DogStatsD + Prometheus) |
| [`configs/dynatrace-extension/extension.yaml`](configs/dynatrace-extension/extension.yaml) | Dynatrace Extensions 2.0 topology and metric ingestion definition |
| [`configs/dynatrace-extension/alerts.json`](configs/dynatrace-extension/alerts.json) | Dynatrace anomaly detection alert definitions for critical Consul metrics |

## Quick Start

1. **Enable Consul telemetry** — apply [`configs/consul-telemetry-agent.hcl`](configs/consul-telemetry-agent.hcl) to every Consul server and client agent.
2. **Deploy Dynatrace OneAgent or ActiveGate** on your OpenShift cluster (see [docs/06-openshift-considerations.md](docs/06-openshift-considerations.md)).
3. **Configure the Dynatrace Extension** — deploy [`configs/dynatrace-extension/extension.yaml`](configs/dynatrace-extension/extension.yaml) via the Dynatrace Hub or API (see [docs/03-dynatrace-metrics-integration.md](docs/03-dynatrace-metrics-integration.md)).
4. **Import alert definitions** — use [`configs/dynatrace-extension/alerts.json`](configs/dynatrace-extension/alerts.json) to bootstrap anomaly detection (see [docs/05-key-metrics-and-alerts.md](docs/05-key-metrics-and-alerts.md)).
5. **Validate log ingestion** — confirm Consul log streams appear in Dynatrace Log Management (see [docs/04-dynatrace-log-monitoring.md](docs/04-dynatrace-log-monitoring.md)).
6. **Enable Envoy L7 metrics and access logs** — configure `proxy-defaults` and annotate application pods (see [docs/07-application-observability.md](docs/07-application-observability.md)).
7. **Configure distributed tracing** — deploy the OpenTelemetry Collector and point it at the Dynatrace OTLP endpoint (see [docs/07-application-observability.md](docs/07-application-observability.md)).

## Reference Documentation

- [Monitor Consul overview](https://developer.hashicorp.com/consul/docs/monitor) — HashiCorp Developer
- [Consul agent telemetry](https://developer.hashicorp.com/consul/docs/monitor/telemetry/agent) — full metrics reference
- [Consul dataplane telemetry](https://developer.hashicorp.com/consul/docs/monitor/telemetry/dataplane)
- [Consul monitoring and alerts](https://developer.hashicorp.com/consul/docs/monitor/alerts)
- [Observe your service mesh](https://developer.hashicorp.com/consul/docs/observe) — access logs, tracing, L7 metrics overview
- [Proxy defaults configuration reference](https://developer.hashicorp.com/consul/docs/reference/config-entry/proxy-defaults) — AccessLogs, envoy_prometheus_bind_addr
- [Consul on RedHat OpenShift](https://developer.hashicorp.com/consul/docs/platform/openshift) — runtime platform guide
- [Envoy cluster statistics](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats) — upstream_rq_*, upstream_cx_* reference
- [Envoy HTTP connection manager statistics](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/stats) — downstream_rq_* reference
- [Dynatrace OpenTelemetry ingest](https://docs.dynatrace.com/docs/ingest-from/opentelemetry) — OTLP trace ingestion
- [Dynatrace Extensions 2.0](https://docs.dynatrace.com/docs/extend-dynatrace/extensions20) — Dynatrace developer documentation
- [Dynatrace Log Management](https://docs.dynatrace.com/docs/observe-and-explore/logs)
