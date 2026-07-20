# Consul Enterprise Monitoring with Dynatrace

This repository provides comprehensive guidance for monitoring **Consul Enterprise** on **Red Hat OpenShift** using **Dynatrace** as the observability backend.

## Who This Is For

Platform and SRE teams that operate Consul Enterprise on OpenShift and use Dynatrace for centralized monitoring, logging, and alerting.

## What This Covers

| Topic | Document |
|---|---|
| Architecture overview and component map | [docs/01-architecture-overview.md](docs/01-architecture-overview.md) |
| Configuring Consul telemetry (DogStatsD / Prometheus) | [docs/02-consul-telemetry-configuration.md](docs/02-consul-telemetry-configuration.md) |
| Ingesting Consul metrics into Dynatrace | [docs/03-dynatrace-metrics-integration.md](docs/03-dynatrace-metrics-integration.md) |
| Ingesting Consul logs into Dynatrace | [docs/04-dynatrace-log-monitoring.md](docs/04-dynatrace-log-monitoring.md) |
| Key metrics, thresholds, and alert definitions | [docs/05-key-metrics-and-alerts.md](docs/05-key-metrics-and-alerts.md) |
| OpenShift-specific considerations | [docs/06-openshift-considerations.md](docs/06-openshift-considerations.md) |

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

## Out of Scope (Future Iteration)

Application-level service mesh observability (Envoy sidecar metrics, L7 traffic metrics, distributed tracing) is planned for a future iteration of this repository.

## Reference Documentation

- [Monitor Consul overview](https://developer.hashicorp.com/consul/docs/monitor) — HashiCorp Developer
- [Consul agent telemetry](https://developer.hashicorp.com/consul/docs/monitor/telemetry/agent) — full metrics reference
- [Consul dataplane telemetry](https://developer.hashicorp.com/consul/docs/monitor/telemetry/dataplane)
- [Consul monitoring and alerts](https://developer.hashicorp.com/consul/docs/monitor/alerts)
- [Consul on RedHat OpenShift](https://developer.hashicorp.com/consul/docs/platform/openshift) — runtime platform guide
- [Dynatrace Extensions 2.0](https://docs.dynatrace.com/docs/extend-dynatrace/extensions20) — Dynatrace developer documentation
- [Dynatrace Log Management](https://docs.dynatrace.com/docs/observe-and-explore/logs)
