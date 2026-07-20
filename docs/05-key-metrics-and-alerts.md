# Key Metrics and Alert Thresholds for Consul

This document consolidates all critical Consul metrics, their thresholds, alert severity definitions, and the corresponding Dynatrace alert configurations. These are derived from the [Consul agent telemetry reference](https://developer.hashicorp.com/consul/docs/monitor/telemetry/agent) and [Consul monitoring and alerts](https://developer.hashicorp.com/consul/docs/monitor/alerts) documentation.

---

## Alert Priority Summary

| Metric | Condition | Severity |
|---|---|---|
| `consul.autopilot.healthy` | value = 0 | **Critical** |
| `consul.raft.leader.lastContact` | avg > 200 ms | **Warning** |
| `consul.raft.state.candidate` | count > 0 per 5 min | **Warning** |
| `consul.runtime.sys_bytes` | > 90% of available node RAM | **Warning** |
| `consul.runtime.total_gc_pause_ns` | rate > 2s/min | **Warning**, > 5s/min **Critical** |
| `consul.raft.commitTime` | p99 > 50% above baseline | **Warning** |
| `consul.client.rpc.exceeded` | count > 0 | **Warning** |
| `consul.client.rpc.failed` | count > 0 | **Warning** |
| `consul.mesh.active_root_ca.expiry` | < 2592000 s (30 days) | **Warning**, < 604800 s (7 days) **Critical** |
| `consul.mesh.active_signing_ca.expiry` | < 86400 s (24 hours) | **Warning** |
| `consul.agent.tls.cert.expiry` | < 604800 s (7 days) | **Warning** |
| `consul.system.licenseExpiration` | < 720 hours (30 days) | **Warning**, < 168 hours (7 days) **Critical** |
| `consul.raft.thread.main.saturation` | avg > 50% | **Warning** |
| `consul.raft.thread.fsm.saturation` | avg > 50% | **Warning** |
| `consul_dataplane.connected` | value = 0 | **Critical** |
| `consul_dataplane.envoy_connected` | value = 0 | **Warning** |

---

## 1. Cluster Health

### Autopilot Health

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.autopilot.healthy` | 1 = all servers healthy, 0 = one or more unhealthy | boolean | Gauge |
| `consul.autopilot.failure_tolerance` | Number of servers the cluster can lose and remain functional | count | Gauge |

**Why it matters:** Autopilot provides a single health boolean for the entire cluster. A value of 0 means the cluster has lost quorum safety margin.

**Alert threshold:** Alert immediately when `consul.autopilot.healthy = 0`.

**Dynatrace alert (DQL):**

```dql
timeseries healthy = min(ext.consul.autopilot.healthy),
  by: { consul.datacenter }
| filter healthy == 0
```

**Recommended action:** Check the Consul server logs for dead or unreachable servers. Run `consul operator raft list-peers` to identify unhealthy peers.

---

## 2. Leadership Stability

### Leadership Change Metrics

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.raft.leader.lastContact` | Time since the leader last contacted follower nodes | ms | Timer |
| `consul.raft.state.candidate` | Increments whenever a server starts an election | elections | Counter |
| `consul.raft.state.leader` | Increments whenever a server becomes leader | leaders | Counter |
| `consul.server.isLeader` | 1 if this server is the leader, 0 otherwise | boolean | Gauge |

**Why they matter:** A healthy Consul cluster has a stable leader. Frequent elections indicate network problems between servers or resource exhaustion. `lastContact` measures the health of the Raft heartbeat channel.

**Alert thresholds:**

- `lastContact` > 200 ms: Warning
- `consul.raft.state.candidate` count > 0 in any 5-minute window: Warning
- `consul.server.isLeader` sum across all servers ≠ 1: Critical (0 = no leader, >1 = split-brain)

**Dynatrace alert (DQL):**

```dql
timeseries elections = sum(ext.consul.raft.state.candidate),
  by: { consul.datacenter },
  interval: 5m
| filter elections > 0
```

---

## 3. Write Performance (Transaction Timing)

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.kvs.apply` | Time to complete a KV store update | ms | Timer |
| `consul.txn.apply` | Time to apply a transaction operation | ms | Timer |
| `consul.raft.apply` | Number of Raft transactions applied per interval (leader only) | count/interval | Counter |
| `consul.raft.commitTime` | Time to commit a new Raft log entry (leader only) | ms | Timer |

**Why they matter:** These metrics represent end-to-end write latency through the Consul cluster. Elevated values indicate server resource pressure, network congestion, or disk I/O saturation.

**Alert threshold:** Deviations of more than 50% from the hourly baseline for any of these metrics.

**Guidance:** Establish a baseline during a known-healthy period. Configure Dynatrace Davis anomaly detection against `consul.raft.commitTime` as it is the most representative write latency metric.

**Dynatrace (Davis auto-adaptive baseline):**

In the Dynatrace UI: **Settings → Anomaly detection → Metric events** → Create event on `ext.consul.raft.commitTime` with:
- Detection method: Auto-adaptive threshold
- Sensitivity: Medium
- Alert condition: Above threshold

---

## 4. Memory Usage

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.runtime.alloc_bytes` | Bytes currently allocated by the Consul process | bytes | Gauge |
| `consul.runtime.sys_bytes` | Total bytes of memory obtained from the OS | bytes | Gauge |
| `consul.runtime.heap_objects` | Number of live objects on the Go heap | count | Gauge |

**Why they matter:** Consul stores the entire service catalog in RAM on server agents. OOM kills cause leadership changes and potential data loss from in-flight state.

**Alert threshold:** Alert when `consul.runtime.sys_bytes` exceeds 90% of the total available node memory. 

**Note:** `sys_bytes` is from Go's `runtime.MemStats` and will differ from `top` output. Do not compare directly to OS-level memory metrics.

**Sizing guidance:** Provision server nodes with 2–4× the value of `consul.runtime.alloc_bytes` under normal operation to allow headroom for traffic spikes.

---

## 5. Garbage Collection

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.runtime.total_gc_pause_ns` | Cumulative nanoseconds in GC pauses since process start | ns | Gauge |

**Why it matters:** Go GC pauses are "stop-the-world" events. Frequent GC under high memory pressure can slow all Consul operations and cause Raft heartbeat timeouts.

**Alert thresholds:**

- Warning: GC pause rate > 2 seconds/minute
- Critical: GC pause rate > 5 seconds/minute

**Important:** `total_gc_pause_ns` is a cumulative counter. To compute the rate in Dynatrace:

```dql
timeseries gc_ns = sum(ext.consul.runtime.total_gc_pause_ns),
  by: { dt.entity.host }
| fieldsAdd gc_rate_per_min = (gc_ns - lag(gc_ns)) / 1000000000 * (60 / interval())
| filter gc_rate_per_min > 2
```

---

## 6. Network / RPC Activity

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.client.rpc` | RPC requests from a Consul agent to a server | requests | Counter |
| `consul.client.rpc.exceeded` | RPC requests that were rate-limited | requests | Counter |
| `consul.client.rpc.failed` | RPC requests that failed | requests | Counter |

**Why they matter:** Elevated RPC counts indicate high agent load. Rate-limited (`exceeded`) or failed RPCs indicate a misconfigured client or an overloaded server.

**Alert thresholds:**

- `consul.client.rpc.exceeded` > 0: Warning — implies rate limiting is active
- `consul.client.rpc.failed` > 0: Warning — implies connectivity or auth issues
- `consul.client.rpc` deviates by > 50% from baseline: Warning

---

## 7. Raft Thread Saturation

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.raft.thread.main.saturation` | Proportion of time the main Raft goroutine is busy | 0–1 | Sample |
| `consul.raft.thread.fsm.saturation` | Proportion of time the FSM goroutine is busy | 0–1 | Sample |

**Why they matter:** These are early-warning proxies for write capacity headroom. Saturation > 50% means the server is using more than half its write processing capacity and is at risk of instability under additional load.

**Alert threshold:** avg saturation > 0.5 (50%) sustained over 5 minutes: Warning.

---

## 8. Raft Replication Capacity

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.raft.fsm.lastRestoreDuration` | Time to restore the last FSM snapshot | ms | Gauge |
| `consul.raft.leader.oldestLogAge` | Age of the oldest log entry in the leader's log store | ms | Gauge |
| `consul.raft.rpc.installSnapshot` | Time for the leader to install a snapshot on a follower | ms | Timer |

**Why they matter:** At high write throughput (500+ commits/second), followers that restart may be unable to catch up via log replication and must repeatedly download snapshots. If restore time approaches `oldestLogAge`, the cluster may lose voting members.

**Alert:** `consul.raft.fsm.lastRestoreDuration` should be less than half of `consul.raft.leader.oldestLogAge` at steady state.

Graph both metrics together in a Dynatrace dashboard tile to observe the safety margin:

```dql
timeseries restore = max(ext.consul.raft.fsm.lastRestoreDuration),
           oldest  = min(ext.consul.raft.leader.oldestLogAge),
  by: { consul.datacenter }
```

---

## 9. TLS Certificate Expiration

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.mesh.active_root_ca.expiry` | Seconds until the service mesh root CA expires | seconds | Gauge |
| `consul.mesh.active_signing_ca.expiry` | Seconds until the signing (intermediate) CA expires | seconds | Gauge |
| `consul.agent.tls.cert.expiry` | Seconds until the agent TLS certificate expires | seconds | Gauge |

**Why they matter:** The mesh stops working when certificates expire. The **root CA is not automatically rotated** by Consul and requires operator action.

**Alert thresholds:**

| Metric | Warning | Critical |
|---|---|---|
| `active_root_ca.expiry` | < 30 days (2,592,000 s) | < 7 days (604,800 s) |
| `active_signing_ca.expiry` | < 24 hours (86,400 s) | < 1 hour (3,600 s) |
| `agent.tls.cert.expiry` | < 7 days (604,800 s) | < 24 hours (86,400 s) |

**Dynatrace alert (DQL) — root CA:**

```dql
timeseries root_ca_expiry = min(ext.consul.mesh.active_root_ca.expiry),
  by: { consul.datacenter }
| filter root_ca_expiry < 2592000
```

---

## 10. Consul Enterprise License Expiration

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul.system.licenseExpiration` | Hours until the Consul Enterprise license expires | hours | Gauge |

**Why it matters:** When the license expires, Enterprise features become unavailable. Namespace operations stop (writes and modifications), and routing based on Enterprise-only features may break.

**Alert thresholds:**

- Warning: < 720 hours (30 days)
- Critical: < 168 hours (7 days)

---

## 11. Consul Dataplane Connectivity

| Metric | Description | Unit | Type |
|---|---|---|---|
| `consul_dataplane.connected` | 1 = connected to a Consul server, 0 = disconnected | boolean | Gauge |
| `consul_dataplane.envoy_connected` | 1 = Envoy connected and receiving xDS, 0 = not | boolean | Gauge |
| `consul_dataplane.connection_errors` | Count of gRPC stream errors (labeled by status code) | count | Gauge |

**Why they matter:** When `consul-dataplane` loses its connection to a Consul server, Envoy stops receiving xDS configuration updates. New services are not discovered, and mTLS certificates cannot be refreshed.

**Alert thresholds:**

- `consul_dataplane.connected = 0`: Critical — dataplane is isolated
- `consul_dataplane.envoy_connected = 0`: Warning — Envoy is not receiving updates
- `consul_dataplane.connection_errors` rate > 0 sustained > 2 minutes: Warning

---

## Recommended Dashboard Layout

Build a Dynatrace dashboard with the following tile layout:

### Row 1: Cluster Health Summary (Single Value Tiles)
- `consul.autopilot.healthy` — green/red indicator
- Active leader count (sum of `consul.server.isLeader`)
- `consul.autopilot.failure_tolerance`
- License expiry hours (Enterprise)

### Row 2: Raft Performance (Time-Series Charts)
- `consul.raft.commitTime` (p50, p95, p99)
- `consul.raft.leader.lastContact`
- `consul.raft.state.candidate` and `consul.raft.state.leader` (as event overlay)

### Row 3: Resource Utilization (Time-Series Charts)
- `consul.runtime.sys_bytes` vs. node memory limit
- `consul.runtime.alloc_bytes`
- GC pause rate (derived from `total_gc_pause_ns`)

### Row 4: Certificate Expiry (Single Value Tiles with Threshold Colors)
- Root CA expiry countdown
- Signing CA expiry countdown
- Agent TLS cert expiry countdown

### Row 5: Dataplane Connectivity (Topology / Count)
- Count of connected dataplanes (`consul_dataplane.connected = 1`)
- Count of disconnected dataplanes (alert-worthy)
- gRPC error rate

---

## Alert Definitions as Code

Ready-to-import Dynatrace anomaly detection alert definitions in JSON format are available at [`configs/dynatrace-extension/alerts.json`](../configs/dynatrace-extension/alerts.json).
