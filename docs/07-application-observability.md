# Application-Level Observability: Envoy L7 Metrics, Access Logs, and Distributed Tracing

This document covers the service mesh data plane layer — what is happening between services, not just whether the Consul cluster itself is healthy. It assumes the control plane monitoring described in the earlier documents is already in place.

The three signal types covered here are:

| Signal | Source | What it tells you |
|---|---|---|
| **L7 traffic metrics** | Envoy sidecar Prometheus endpoint | Request rate, error rate, latency distribution per service-to-service path |
| **Envoy access logs** | Consul proxy-defaults `AccessLogs` + Envoy stdout | Per-request detail: status code, duration, upstream cluster, response flags |
| **Distributed traces** | Envoy + application OTLP instrumentation → Dynatrace | End-to-end request flow across service boundaries, latency breakdown per span |

---

## Prerequisites

Before configuring application observability, confirm:

- `connectInject.enabled = true` in the Consul Helm chart — sidecars are being injected into application pods.
- `envoy_prometheus_bind_addr` is set in the `proxy-defaults` config entry (covered in [docs/02-consul-telemetry-configuration.md](./02-consul-telemetry-configuration.md)) — the merged metrics endpoint at port 20200 is live.
- Dynatrace ActiveGate is deployed and scraping Consul control plane metrics (covered in [docs/03-dynatrace-metrics-integration.md](./03-dynatrace-metrics-integration.md)).

---

## Part 1: Envoy L7 Traffic Metrics

### How Envoy Exposes Metrics

Each Envoy sidecar exposes a Prometheus metrics endpoint that includes statistics for every upstream cluster (outbound connections to other services) and every downstream listener (inbound connections to the local service). When `envoy_prometheus_bind_addr` is set in `proxy-defaults`, `consul-dataplane` merges Envoy's metrics with its own `consul_dataplane.*` metrics and serves them from a single endpoint:

```
http://<pod-ip>:20200/metrics
```

Envoy metric names follow the pattern:

```
envoy_cluster_<upstream_cluster_name>_<stat_name>
envoy_http_<listener_name>_<stat_name>
```

In a Consul service mesh, the upstream cluster name encodes the destination service, namespace, datacenter, and protocol. For example:

```
envoy_cluster_billing_default_dc1_internal_upstream_rq_total
```

### Key L7 Metrics to Collect

#### Per-Service Request Rate, Error Rate, and Latency (RED)

These are the core metrics for service health monitoring — collectively the RED (Rate, Error, Duration) signals.

| Envoy Metric | Description | Type |
|---|---|---|
| `envoy_cluster_<name>_upstream_rq_total` | Total requests sent to the upstream service | Counter |
| `envoy_cluster_<name>_upstream_rq_2xx` | Requests that received a 2xx response | Counter |
| `envoy_cluster_<name>_upstream_rq_4xx` | Requests that received a 4xx response (client errors) | Counter |
| `envoy_cluster_<name>_upstream_rq_5xx` | Requests that received a 5xx response (server errors) | Counter |
| `envoy_cluster_<name>_upstream_rq_time` | Request duration histogram (milliseconds) | Histogram |
| `envoy_cluster_<name>_upstream_rq_timeout` | Requests that timed out before a response | Counter |
| `envoy_cluster_<name>_upstream_rq_pending_total` | Requests waiting for a connection pool slot | Counter |
| `envoy_cluster_<name>_upstream_rq_retry` | Total request retries | Counter |
| `envoy_cluster_<name>_upstream_rq_retry_limit_exceeded` | Requests dropped because retry budget was exhausted | Counter |

#### Inbound (Downstream) Request Metrics

These measure what each service is receiving — useful for correlating client-reported 5xx with server-observed request counts.

| Envoy Metric | Description | Type |
|---|---|---|
| `envoy_http_<listener>_downstream_rq_total` | Total inbound requests received | Counter |
| `envoy_http_<listener>_downstream_rq_2xx` | Inbound requests with 2xx response | Counter |
| `envoy_http_<listener>_downstream_rq_4xx` | Inbound requests with 4xx response | Counter |
| `envoy_http_<listener>_downstream_rq_5xx` | Inbound requests with 5xx response | Counter |
| `envoy_http_<listener>_downstream_rq_time` | Inbound request latency histogram (ms) | Histogram |
| `envoy_http_<listener>_downstream_cx_active` | Active inbound connections | Gauge |

#### Connection Pool Health

Circuit breaker state is visible through connection pool overflow metrics:

| Envoy Metric | Description | Type |
|---|---|---|
| `envoy_cluster_<name>_upstream_cx_active` | Active upstream connections | Gauge |
| `envoy_cluster_<name>_upstream_cx_connect_fail` | Connection failures to the upstream | Counter |
| `envoy_cluster_<name>_upstream_cx_connect_timeout` | Connection attempts that timed out | Counter |
| `envoy_cluster_<name>_upstream_cx_overflow` | Requests rejected due to connection circuit breaker | Counter |
| `envoy_cluster_<name>_upstream_rq_pending_overflow` | Requests rejected due to pending request circuit breaker | Counter |
| `envoy_cluster_<name>_upstream_cx_none_healthy` | Requests dropped because no healthy upstream endpoints exist | Counter |

### Configuring Envoy Prometheus Metrics

Enable merged metrics via the `proxy-defaults` config entry. Apply this to your Consul cluster:

```hcl
# proxy-defaults-observability.hcl
Kind = "proxy-defaults"
Name = "global"

Config {
  # Expose merged consul-dataplane + Envoy metrics on port 20200
  envoy_prometheus_bind_addr = "0.0.0.0:20200"

  # Protocol must be set per-service for L7 stats to be emitted.
  # Set this in per-service service-defaults config entries instead
  # if services use different protocols.
  protocol = "http"
}
```

Apply it:

```bash
consul config write proxy-defaults-observability.hcl
```

> **Important:** Envoy only emits L7 request statistics (rq_total, rq_5xx, rq_time, etc.) when the upstream cluster protocol is set to `http`, `http2`, or `grpc`. If the protocol is `tcp` (the default), only connection-level counters are emitted. Set the protocol in the `service-defaults` config entry for each service:
>
> ```hcl
> Kind     = "service-defaults"
> Name     = "billing"
> Protocol = "http"
> ```

### Configuring Dynatrace ActiveGate to Scrape Envoy Metrics

The Envoy metrics endpoint at pod IP:20200 must be scraped by Dynatrace ActiveGate. On OpenShift, configure scraping using the Dynatrace Operator's `MetricIngest` capability or a custom extension scrape configuration.

Add the following to your `DynaKube` custom resource to enable Prometheus annotation-based scraping:

```yaml
apiVersion: dynatrace.com/v1beta1
kind: DynaKube
metadata:
  name: consul-monitoring
  namespace: dynatrace
spec:
  metricIngest:
    enabled: true
```

Then annotate application pods to be scraped:

```yaml
# Add to the pod template in your application Deployment / StatefulSet
annotations:
  metrics.dynatrace.com/scrape: "true"
  metrics.dynatrace.com/port: "20200"
  metrics.dynatrace.com/path: "/metrics"
  metrics.dynatrace.com/secure: "false"
```

Alternatively, add the annotations globally for all injected pods by setting them in the Consul Helm chart:

```yaml
connectInject:
  annotations:
    metrics.dynatrace.com/scrape: "true"
    metrics.dynatrace.com/port: "20200"
    metrics.dynatrace.com/path: "/metrics"
```

### L7 Metric Alert Thresholds

| Metric | Condition | Severity |
|---|---|---|
| `upstream_rq_5xx` rate | > 1% of `upstream_rq_total` over 5 min | Warning |
| `upstream_rq_5xx` rate | > 5% of `upstream_rq_total` over 5 min | Critical |
| `upstream_rq_time` p99 | > 500 ms sustained 5 min | Warning |
| `upstream_rq_time` p99 | > 2000 ms sustained 5 min | Critical |
| `upstream_cx_none_healthy` | count > 0 | Critical — no healthy endpoints for a service |
| `upstream_cx_overflow` | count > 0 | Warning — circuit breaker active |
| `upstream_rq_pending_overflow` | count > 0 | Warning — request queue saturated |

**DQL for error rate across all services:**

```dql
timeseries rq_total = sum(envoy_cluster_upstream_rq_total),
           rq_5xx   = sum(envoy_cluster_upstream_rq_5xx),
  by: { k8s.pod.name, k8s.namespace }
| fieldsAdd error_rate = rq_5xx / rq_total * 100
| filter error_rate > 1
| sort error_rate desc
```

---

## Part 2: Envoy Access Logs

Access logs provide per-request detail that aggregate metrics cannot — the exact status code, response duration, upstream host, and Envoy response flags for every connection through the proxy. They are the first place to look when a service is reporting errors but the cause is unclear.

### Enabling Access Logs in Consul

Access logs are configured globally via the `proxy-defaults` config entry `AccessLogs` block:

```hcl
Kind = "proxy-defaults"
Name = "global"

AccessLogs {
  Enabled = true

  # Emit to stdout so OpenShift/Kubernetes routes logs through the
  # standard container log pipeline to Dynatrace
  Type = "stdout"

  # JSON format — enables structured field extraction in Dynatrace
  JSONFormat = "{\"start_time\":\"%START_TIME%\",\"method\":\"%REQ(:METHOD)%\",\"path\":\"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%\",\"protocol\":\"%PROTOCOL%\",\"response_code\":\"%RESPONSE_CODE%\",\"response_flags\":\"%RESPONSE_FLAGS%\",\"bytes_received\":\"%BYTES_RECEIVED%\",\"bytes_sent\":\"%BYTES_SENT%\",\"duration\":\"%DURATION%\",\"upstream_service_time\":\"%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%\",\"upstream_host\":\"%UPSTREAM_HOST%\",\"upstream_cluster\":\"%UPSTREAM_CLUSTER%\",\"downstream_remote_address\":\"%DOWNSTREAM_REMOTE_ADDRESS%\",\"request_id\":\"%REQ(X-REQUEST-ID)%\",\"trace_id\":\"%REQ(X-B3-TRACEID)%\"}"
}
```

Apply with:

```bash
consul config write proxy-defaults-observability.hcl
```

> **Note:** `DisableListenerLogs = false` (the default) means Envoy also logs connections for traffic it does not recognize. Set `DisableListenerLogs = true` to suppress those if they generate noise in your log stream.

### Access Log Fields Reference

The JSON format above produces the following fields, all of which Dynatrace can extract as log attributes:

| Field | Description |
|---|---|
| `start_time` | Request start timestamp |
| `method` | HTTP method (GET, POST, etc.) |
| `path` | Request path |
| `protocol` | Protocol (HTTP/1.1, HTTP/2, etc.) |
| `response_code` | HTTP response status code |
| `response_flags` | Envoy response flags — see table below |
| `duration` | Total request duration (ms) |
| `upstream_service_time` | Time the upstream service spent processing the request (ms) |
| `upstream_host` | IP:port of the upstream pod that served the request |
| `upstream_cluster` | Upstream Consul service cluster name |
| `request_id` | Unique request ID (set by Envoy if not present in the request) |
| `trace_id` | Distributed trace ID (if tracing is enabled) |

### Envoy Response Flags

`response_flags` is the most important field for diagnosing proxy-level errors. Key values:

| Flag | Meaning | Typical Cause |
|---|---|---|
| `UH` | No healthy upstream | All endpoints for the target service are down or failing health checks |
| `UF` | Upstream connection failure | TCP connection to upstream pod failed |
| `UO` | Upstream overflow | Circuit breaker tripped — connection or request limit reached |
| `UT` | Upstream request timeout | Upstream did not respond within the configured timeout |
| `URX` | Upstream retry limit exceeded | All retries exhausted without a successful response |
| `NR` | No route | No routing rule matched the request — usually a misconfigured service intention or missing service-router |
| `DC` | Downstream connection termination | Client disconnected before the response was sent |
| `FI` | Fault injection | A fault injection policy terminated the request (useful in testing) |

### Dynatrace Log Processing for Access Logs

Create a log processing rule to extract access log fields as attributes:

1. **Settings → Log Monitoring → Log processing rules** → New rule.
2. Matcher: `k8s.container.name = "consul-dataplane"` (access logs appear on the `consul-dataplane` container's stdout).
3. Processor: JSON parse on the full log line.
4. Map `response_code` → `http.response_status_code`, `duration` → `envoy.duration_ms`, `upstream_cluster` → `envoy.upstream_cluster`, `response_flags` → `envoy.response_flags`.

**DQL to find all non-2xx upstream responses in the last hour:**

```dql
fetch logs
| filter k8s.container.name == "consul-dataplane"
  and isNotNull(http.response_status_code)
  and toInt(http.response_status_code) >= 400
| summarize count(), by: { http.response_status_code, envoy.upstream_cluster, envoy.response_flags }
| sort count() desc
```

**DQL to surface circuit-breaker events (`UO`) across all services:**

```dql
fetch logs
| filter k8s.container.name == "consul-dataplane"
  and matchesPhrase(envoy.response_flags, "UO")
| summarize count(), by: { envoy.upstream_cluster, k8s.namespace }
| sort count() desc
```

---

## Part 3: Distributed Tracing

Distributed tracing tracks individual requests as they flow across service boundaries, stitching together the spans produced by each service and proxy into a single trace. This is the observability signal that answers "which hop is slow?" and "where did this request fail?"

### Architecture

```
Service A (app)  ──OTLP──►  Dynatrace OTLP ingest
     │ propagates
     │ trace context
     ▼ (HTTP header: traceparent)
Envoy sidecar A  ──Zipkin/OTLP──► Dynatrace
     │
     ▼ (mTLS, mesh)
Envoy sidecar B
     │
     ▼
Service B (app)  ──OTLP──►  Dynatrace OTLP ingest
```

Envoy can emit spans for every proxied connection without any changes to application code. Application-level spans (which capture business context, database calls, etc.) require OTLP instrumentation in the application.

### Configuring Envoy to Emit Traces

Envoy's tracing provider is configured via the `proxy-defaults` `Config` block using the Envoy bootstrap passthrough:

```hcl
Kind = "proxy-defaults"
Name = "global"

Config {
  envoy_prometheus_bind_addr = "0.0.0.0:20200"
  protocol                   = "http"

  # Zipkin-compatible tracing (Dynatrace accepts Zipkin format via its
  # OTLP/Zipkin endpoint)
  "envoy_tracing_json" = jsonencode({
    http = {
      name = "envoy.tracers.zipkin"
      typedConfig = {
        "@type"              = "type.googleapis.com/envoy.config.trace.v3.ZipkinConfig"
        collector_cluster    = "datadog_agent"
        collector_endpoint   = "/api/v2/spans"
        shared_span_context  = false
        collector_endpoint_version = "HTTP_JSON"
      }
    }
  })
}
```

> For Dynatrace, the preferred approach is to point Envoy at the Dynatrace OTLP endpoint via a collector sidecar or the Dynatrace ActiveGate OTLP receiver. See the Dynatrace OpenTelemetry ingestion documentation for current endpoint configuration.

### Configuring Dynatrace as the OTLP Backend

Dynatrace natively accepts OpenTelemetry traces via the OTLP gRPC and HTTP protocols. Configure the Dynatrace OTLP ingest endpoint in the OpenTelemetry collector deployed on your OpenShift cluster:

```yaml
# otel-collector-config.yaml
exporters:
  otlphttp:
    endpoint: "https://<your-tenant>.live.dynatrace.com/api/v2/otlp"
    headers:
      Authorization: "Api-Token <token-with-openTelemetryTrace.ingest-scope>"

processors:
  batch:
    timeout: 5s
  resource:
    attributes:
      - key: k8s.cluster.name
        value: "openshift-prod"
        action: upsert

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [otlphttp]
```

Deploy the collector as a Deployment in the `dynatrace` namespace and expose it as a Kubernetes Service so application pods can reach it via `http://otel-collector.dynatrace.svc:4317` (gRPC) or `:4318` (HTTP).

### Propagating Trace Context Through the Mesh

For traces to stitch together across service boundaries, each service must:

1. **Read the incoming `traceparent` header** (W3C Trace Context) or `X-B3-TraceId`/`X-B3-SpanId` (Zipkin B3) from the inbound request.
2. **Forward those headers** on every outbound call it makes.

Envoy propagates trace headers between the inbound and outbound sides of the sidecar automatically. The application only needs to forward headers it receives — it does not need to generate new ones (unless it is the originating service).

For OpenTelemetry-instrumented applications, use the OTLP SDK with the W3C TraceContext propagator:

```python
# Python example
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.b3 import B3MultiFormat

set_global_textmap(B3MultiFormat())
```

### Viewing Traces in Dynatrace

Once traces are flowing, use Dynatrace Distributed Traces (under **Observe and Explore → Distributed Traces**) to:

- Filter traces by service name, status code, or minimum duration.
- Identify the slowest spans in a trace waterfall.
- Correlate a trace ID from an Envoy access log (`trace_id` field) with the full distributed trace in Dynatrace.

**DQL to join an access log error with its trace:**

```dql
fetch logs
| filter k8s.container.name == "consul-dataplane"
  and http.response_status_code == "500"
| fields timestamp, envoy.upstream_cluster, trace_id, envoy.response_flags
| limit 20
```

Take the `trace_id` value and look it up directly in Distributed Traces to see the full request path.

---

## Recommended Dashboard Layout (Application Observability)

Add a second dashboard (or additional rows to the existing control plane dashboard) covering:

### Row 1: Service Traffic Overview
- Request rate per service (`upstream_rq_total` rate, split by upstream cluster)
- Error rate per service (5xx / total)
- p99 latency per service (`upstream_rq_time`)

### Row 2: Circuit Breaker and Connection Health
- `upstream_cx_none_healthy` — services with no healthy endpoints (should always be 0)
- `upstream_cx_overflow` and `upstream_rq_pending_overflow` — circuit breaker activations
- `upstream_cx_connect_fail` rate — upstream connection failure rate

### Row 3: Access Log Error Distribution
- Top response flags by frequency (DQL-powered table tile)
- Top error-producing upstream clusters
- p95/p99 `duration` from access logs (actual per-request latency including Envoy overhead)

### Row 4: Distributed Trace Summary
- Trace throughput (spans/sec)
- Error span rate
- Slowest services by average span duration (P95)

---

## Envoy Metric Labels and Dynatrace Dimensions

The Envoy metric names include the upstream cluster name, which encodes service identity in Consul's format:

```
<service>.<namespace>.<datacenter>.<protocol>.internal
```

For example: `billing.default.dc1.http.internal`

When ingesting into Dynatrace, split this into separate dimensions using a metric processing rule:

```
consul.service    = billing
consul.namespace  = default
consul.datacenter = dc1
```

This enables cross-service dashboards and alerts that filter by namespace or datacenter without requiring separate scrape targets per service.
