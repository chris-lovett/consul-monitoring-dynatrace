# Consul Log Monitoring with Dynatrace

Consul server agents, client agents, and `consul-dataplane` all emit structured logs to stdout/stderr. On OpenShift, the container runtime captures these logs and makes them available via the standard Kubernetes log pipeline. Dynatrace can ingest these logs through multiple paths.

## Log Architecture on OpenShift

```
Consul Pod (stdout/stderr)
       │
       ▼
OpenShift Node log driver (journald / CRI-O)
       │
       ├── /var/log/containers/<pod>.log
       │
       ▼
Dynatrace OneAgent (log ingest)
       │
       ▼
Dynatrace Log Management and Analytics
```

Dynatrace OneAgent automatically discovers and tails log files for all pods on each OpenShift node, provided log ingest is enabled in the OneAgent configuration.

---

## Enabling Consul Log Collection in Dynatrace

### Step 1: Enable Log Monitoring in OneAgent

In the Dynatrace UI: **Settings → Log Monitoring → Log sources and storage**.

Enable **Kubernetes** as a log source. OneAgent will automatically discover Consul pods and begin tailing their logs.

### Step 2: Configure Log Ingest Rules for Consul

Create a log ingest rule to label Consul logs with the relevant entity context:

1. Navigate to **Settings → Log Monitoring → Log ingest rules**.
2. Create a rule with the following filter:
   - **Kubernetes container name**: `consul` (matches server, client, dataplane containers)
   - **Kubernetes namespace**: `consul` (adjust to your deployment namespace)

This ensures Consul logs are associated with the Consul service entity in Dynatrace rather than treated as generic container logs.

### Step 3: Configure Log Processing Rules

Add a log processing rule to extract structured fields from Consul's JSON log output.

Consul server agents can be configured to emit JSON-formatted logs using:

```hcl
# In the Consul agent configuration
log_json = true
log_level = "INFO"
```

A JSON Consul log line looks like:

```json
{
  "@timestamp": "2024-01-15T10:23:45.123Z",
  "@level": "warn",
  "@message": "Raft: failed to contact follower",
  "@module": "agent.raft",
  "follower": "10.0.0.5:8300",
  "time_since_contact": "4.2s"
}
```

Create a Dynatrace log processing rule to promote these JSON fields to log attributes:

```json
{
  "processorType": "JSON",
  "rule": {
    "matcher": "k8s.container.name = \"consul\"",
    "processor": {
      "type": "json-parse",
      "fields": ["@level", "@message", "@module", "@timestamp"]
    },
    "attributeMapping": {
      "log.level": "@level",
      "log.module": "@module"
    }
  }
}
```

---

## Key Log Events to Monitor

### Leadership Changes

Leadership changes are a critical indicator of cluster instability. Look for log messages from the `agent.raft` module:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `raft: entering candidate state` | A server has started an election | Warning |
| `raft: entering leader state` | A new leader has been elected | Info |
| `raft: heartbeat timeout reached` | A follower lost contact with the leader | Warning |
| `Failed to contact` with `time_since_contact > 200ms` | Leader lease violation | Warning |

**DQL query for leadership changes:**

```dql
fetch logs
| filter k8s.container.name == "consul"
  and (matchesPhrase(content, "entering candidate state")
    or matchesPhrase(content, "entering leader state"))
| sort timestamp desc
| fields timestamp, k8s.pod.name, content
```

### ACL Rejections

ACL token rejections can indicate misconfigured workloads or security incidents:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `Permission denied` | A request was rejected by the ACL system | Warning |
| `ACL not found` | An unknown token was presented | Warning |
| `token lacks permission` | Insufficient token privileges | Warning |

**DQL query for ACL rejections:**

```dql
fetch logs
| filter k8s.container.name == "consul"
  and (matchesPhrase(content, "Permission denied")
    or matchesPhrase(content, "ACL not found")
    or matchesPhrase(content, "lacks permission"))
| sort timestamp desc
```

### Certificate / TLS Errors

TLS failures can indicate expired certificates or misconfiguration:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `certificate has expired` | A TLS certificate has expired | Critical |
| `x509: certificate signed by unknown authority` | Trust chain issue | Error |
| `CA rotation` | Certificate Authority rotation in progress | Info |
| `failed to rotate` | Certificate rotation failed — requires operator action | Error |

**DQL query for TLS/CA log events:**

```dql
fetch logs
| filter k8s.container.name == "consul"
  and (matchesPhrase(content, "certificate")
    or matchesPhrase(content, "CA rotation")
    or matchesPhrase(content, "TLS"))
| filter log.level == "ERROR" or log.level == "WARN"
| sort timestamp desc
```

### License Warnings (Enterprise)

Consul Enterprise emits warnings in the logs as the license approaches expiration:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `License expires in` | Upcoming license expiry | Warning |
| `License is expired` | License has expired — degraded functionality | Critical |

**DQL query for license events:**

```dql
fetch logs
| filter k8s.container.name == "consul"
  and matchesPhrase(content, "License")
| filter log.level == "WARN" or log.level == "ERROR"
| sort timestamp desc
```

### Health Check Failures

Service health check failures affect service discovery and traffic routing:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `Health check failing` | A registered check has gone critical | Warning |
| `Deregistered service` | A service instance was removed | Info |
| `agent: Check is now critical` | A check transitioned to critical state | Warning |

### consul-dataplane gRPC Errors

`consul-dataplane` logs gRPC stream errors when connectivity to Consul servers is degraded:

| Log Message Pattern | Meaning | Severity |
|---|---|---|
| `failed to connect` | Dataplane cannot reach any Consul server | Critical |
| `xDS stream` error | Envoy xDS configuration delivery failed | Error |
| `re-connecting` | Dataplane is retrying server connection | Warning |

---

## Setting Up Dynatrace Log Alerts (Davis Anomaly Detection)

### Create a Log Metric

Convert the log query for leadership changes into a metric for alerting:

1. **Settings → Log Monitoring → Log metrics**.
2. Create a new log metric:
   - **Name**: `log:consul.leadership.changes`
   - **DQL**: 
     ```dql
     fetch logs
     | filter k8s.container.name == "consul"
       and matchesPhrase(content, "entering candidate state")
     | summarize count()
     ```
3. This produces a time-series metric you can alert on.

### Create an Anomaly Detection Rule

1. Navigate to **Settings → Anomaly detection → Custom events for alerting**.
2. Create a new event with:
   - **Metric**: `log:consul.leadership.changes`
   - **Condition**: `avg > 1 per 5 minutes`
   - **Severity**: Problem
   - **Title**: `Consul leadership instability detected`

---

## Log Retention and Storage

Consul control plane logs contain sensitive operational data including IP addresses, service names, and token metadata. Configure log retention in Dynatrace appropriately:

- **Recommended retention**: 30 days for operational troubleshooting
- **ACL audit logs**: Consider longer retention (90+ days) for compliance

Dynatrace Log Management storage buckets can be configured in **Settings → Log Monitoring → Log storage configuration**.

---

## Configuring Log Format in Consul

To get the most out of Dynatrace log processing, configure Consul to emit JSON-formatted logs. Add to each agent configuration:

```hcl
log_level  = "INFO"
log_json   = true
```

For Consul server agents deployed via Helm on OpenShift, set in `values.yaml`:

```yaml
server:
  extraConfig: |
    {
      "log_level": "INFO",
      "log_json": true
    }
```

For `consul-dataplane`, pass the `-log-json` and `-log-level` flags in the container command args:

```yaml
command:
  - /bin/consul-dataplane
  - -log-json
  - -log-level=info
```
