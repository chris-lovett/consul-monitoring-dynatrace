# Architecture Overview: Consul Enterprise on OpenShift with Dynatrace

## Consul Control Plane and Data Plane

A Consul datacenter is the smallest unit of Consul infrastructure capable of performing service discovery and service mesh operations. In a production Consul Enterprise deployment on OpenShift you will have:

| Component | Role | Typical Count |
|---|---|---|
| **Consul Server Agents** | Store all state: service registrations, health checks, KV, configuration entries, ACL tokens. Form the Raft quorum. | 3 or 5 |
| **Consul Client Agents** | Run on each node/pod. Report health status, forward RPC to servers. | One per node (VM deployments) |
| **Consul Dataplane** (`consul-dataplane`) | Lightweight replacement for client agents in Kubernetes/OpenShift. Connects to servers over gRPC. Manages Envoy lifecycle. | One per sidecar pod |
| **Envoy Sidecar Proxies** | Data plane — intercept and route all service mesh traffic. Managed by `consul-dataplane`. | One per service instance |
| **API Gateway** | Ingress for north/south traffic into the mesh. | Per namespace / cluster |

### OpenShift Deployment Model

On OpenShift, Consul Enterprise is typically deployed via the [Consul Helm chart](https://developer.hashicorp.com/consul/docs/k8s/installation/install) with `connectInject.enabled=true`. The `consul-dataplane` binary replaces the traditional client agent for sidecar-injected workloads.

```
┌─────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                              │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  consul namespace                                        │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│  │  │ consul-srv-0│  │ consul-srv-1│  │ consul-srv-2│     │   │
│  │  │  (server)   │  │  (server)   │  │  (server)   │     │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │   │
│  │         └────────────────┴────────────────┘             │   │
│  │                      Raft Cluster                        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────┐                              │
│  │  application namespace       │                              │
│  │  ┌────────────────────────┐  │                              │
│  │  │  App Pod               │  │                              │
│  │  │  ┌──────┐ ┌──────────┐ │  │                              │
│  │  │  │ app  │ │ envoy    │ │  │                              │
│  │  │  │      │ │ sidecar  │ │  │                              │
│  │  │  └──────┘ └──────────┘ │  │                              │
│  │  │  ┌──────────────────┐  │  │                              │
│  │  │  │ consul-dataplane │  │  │                              │
│  │  │  └──────────────────┘  │  │                              │
│  │  └────────────────────────┘  │                              │
│  └──────────────────────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

## What Needs to Be Monitored

Consul monitoring spans three layers:

### 1. Infrastructure / Host Resources (Instance-level)

Monitor these on every node running a Consul server or client agent:

| Resource | Why |
|---|---|
| **Disk space and file handles** | Consul servers write Raft snapshots and WAL segments to disk. Disk exhaustion causes crashes. |
| **RAM utilization** | Consul stores the entire service catalog in memory on server agents. OOM kills cause leadership changes. |
| **CPU utilization** | Mass registration/deregistration events fan out to all clients simultaneously and can spike CPU on servers. |
| **Network latency (RTT)** | Consul requires average RTT ≤ 50 ms and p99 RTT ≤ 100 ms across all agents. |

### 2. Consul Agent Telemetry (Application-level metrics)

The Consul agent emits metrics for all internal subsystems every 10 seconds to DogStatsD/StatsD, or every 60 seconds via a Prometheus scrape endpoint. Key subsystems:

- **Raft** — consensus protocol health, commit latency, leadership stability
- **RPC** — request rates, rate-limiting, failures
- **Autopilot** — overall cluster health boolean
- **Runtime** — Go memory and GC behavior
- **TLS / CA** — certificate expiration countdowns
- **License** (Enterprise) — hours until license expiry
- **WAL / BoltDB** — persistent storage backend performance

### 3. Logs

Consul server and dataplane components emit structured logs to stdout/stderr, which OpenShift routes to the container log driver. Log levels and content are critical for:

- Leadership election events
- ACL token rejections
- Health check failures
- TLS/CA certificate rotation events
- License warnings
- gRPC stream errors (consul-dataplane)

## Dynatrace Monitoring Architecture

```
Consul Agent / Dataplane
        │
        │  DogStatsD (UDP :8125)  ──────────────────────────┐
        │  Prometheus (/v1/agent/metrics?format=prometheus)  │
        │  Stdout logs (OpenShift log pipeline)              │
        ▼                                                    │
Dynatrace OneAgent (on each OpenShift node)                 │
        │                                                    │
        │  Metric ingest API  ──────────────────────────────►│
        │  Log ingest API ──────────────────────────────────►│
        ▼                                                    ▼
Dynatrace ActiveGate ──────────────────────────► Dynatrace SaaS / Managed
        │
        │  Scrapes Prometheus endpoint (pull model)
        ▼
Consul metrics API  /v1/agent/metrics?format=prometheus
```

Two ingestion paths are supported and can be used independently or together:

| Path | Mechanism | Best For |
|---|---|---|
| **Push (DogStatsD)** | Consul agent pushes metrics to DogStatsD listener every 10s | Low latency, fire-and-forget |
| **Pull (Prometheus)** | Dynatrace ActiveGate scrapes `/v1/agent/metrics?format=prometheus` every 60s | Standard OpenShift observability pattern |

## Monitoring Scope for This Repository

This repository covers **infrastructure + control plane monitoring**:

- ✅ Consul server agent health and Raft consensus
- ✅ Consul client agent / dataplane connectivity
- ✅ Certificate and license expiry
- ✅ Host resource monitoring
- ✅ Consul structured log collection and alerting

**Out of scope (future iteration):**

- ❌ Envoy / service mesh L7 traffic metrics (request rate, error rate, latency per service)
- ❌ Distributed tracing across services
- ❌ Application-level Dynatrace APM instrumentation
