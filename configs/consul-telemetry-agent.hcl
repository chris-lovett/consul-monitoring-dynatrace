# Consul Agent Telemetry Configuration
# -----------------------------------------
# Apply this file to every Consul server and client agent in the OpenShift
# deployment. Place it in the Consul configuration directory (default:
# /etc/consul.d/) or mount it via a Kubernetes ConfigMap.
#
# See: https://developer.hashicorp.com/consul/docs/monitor/telemetry/agent
# See: docs/02-consul-telemetry-configuration.md

telemetry {
  # -------------------------------------------------------------------
  # DogStatsD (push)
  # Consul pushes metrics to the Dynatrace OneAgent DogStatsD listener
  # every 10 seconds. HOST_IP is injected via the Kubernetes Downward API
  # (see docs/06-openshift-considerations.md).
  # -------------------------------------------------------------------
  dogstatsd_addr = "${HOST_IP}:8125"

  # Tag all metrics with the datacenter and agent role so Dynatrace can
  # filter and split metrics per datacenter and per server/client.
  dogstatsd_tags = [
    "consul_datacenter:dc1",  # Update to match your datacenter name
    "consul_role:server",     # Set to "client" for client agent configs
  ]

  # -------------------------------------------------------------------
  # Prometheus (pull)
  # Exposes /v1/agent/metrics?format=prometheus for Dynatrace ActiveGate
  # scraping. Metrics are retained in memory for 60 seconds — one full
  # Prometheus scrape interval.
  # -------------------------------------------------------------------
  prometheus_retention_time = "60s"

  # -------------------------------------------------------------------
  # General settings
  # -------------------------------------------------------------------

  # Disable hostname prefix on gauge metrics. Dynatrace handles host
  # dimensioning via its entity model; including the hostname in the
  # metric name would create unbounded metric cardinality.
  disable_hostname = true

  # Metric name prefix applied to all emitted metrics.
  # Matches the consul.* namespace used throughout this repository.
  metrics_prefix = "consul"

  # Do not retain in-memory metrics beyond what the external store needs.
  # Set to a positive duration if you need the /v1/agent/metrics JSON
  # endpoint for ad-hoc querying (e.g., "10m").
  retention_time = "0s"
}

# -------------------------------------------------------------------
# Log format
# Configure JSON log output so Dynatrace log processing rules can
# extract structured fields (@level, @message, @module) as log
# attributes.
#
# See: docs/04-dynatrace-log-monitoring.md
# -------------------------------------------------------------------
log_level = "INFO"
log_json  = true
