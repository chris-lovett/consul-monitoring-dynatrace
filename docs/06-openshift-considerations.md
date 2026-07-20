# OpenShift-Specific Considerations for Consul + Dynatrace

This document covers the configuration differences, RBAC requirements, SecurityContextConstraints (SCC), and networking considerations specific to running Consul Enterprise on Red Hat OpenShift with Dynatrace monitoring.

---

## Consul Helm Deployment on OpenShift

HashiCorp maintains a [Consul Helm chart](https://developer.hashicorp.com/consul/docs/k8s/installation/install) that supports OpenShift via the `global.openshift.enabled = true` values flag. This enables the necessary SCC annotations and adjusts the security context for Consul components.

### Key Helm Values for OpenShift

```yaml
# values.yaml
global:
  name: consul
  datacenter: dc1

  # Enable OpenShift-specific SCC and security context adjustments
  openshift:
    enabled: true

  # Enable ACLs (required for Consul Enterprise)
  acls:
    manageSystemACLs: true

  # Enable TLS for all agent-to-agent communication
  tls:
    enabled: true
    enableAutoEncrypt: true

  # Enterprise license
  enterpriseLicense:
    secretName: consul-ent-license
    secretKey: key

server:
  replicas: 3
  extraConfig: |
    {
      "log_level": "INFO",
      "log_json": true
    }

  # Mount the telemetry ConfigMap
  extraVolumes:
    - type: configMap
      name: consul-telemetry-config
      load: true

connectInject:
  enabled: true
  default: false  # Opt-in per namespace with annotation
```

### OpenShift Annotations for Consul Namespaces

Pods in the Consul namespace require the `anyuid` or a custom SCC. When `global.openshift.enabled = true`, the Helm chart automatically applies the required annotations. Verify with:

```bash
oc get pods -n consul -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'
```

---

## SecurityContextConstraints (SCC)

### Consul Server and Client Agents

The `consul-server` StatefulSet requires the `restricted-v2` SCC (OpenShift 4.11+) or `restricted` (earlier versions) because Consul does not require root and runs as a non-root UID by default.

If custom SCCs are required by your organization's policy, the minimum required capabilities are:

```yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: consul-scc
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
fsGroup:
  type: MustRunAs
  ranges:
    - min: 1000
      max: 65534
runAsUser:
  type: MustRunAsRange
  uidRangeMin: 1000
  uidRangeMax: 65534
seLinuxContext:
  type: MustRunAs
volumes:
  - configMap
  - emptyDir
  - persistentVolumeClaim
  - projected
  - secret
```

### Dynatrace OneAgent on OpenShift

Dynatrace OneAgent requires elevated privileges to instrument processes on OpenShift nodes. The Dynatrace Operator deploys OneAgent as a DaemonSet with `privileged` SCC.

```bash
# Check OneAgent SCC assignment
oc get scc privileged -o jsonpath='{.users}'
# Should include: system:serviceaccount:dynatrace:dynatrace-dynakube-oneagent
```

The Dynatrace Operator manages this automatically when deployed via OperatorHub or Helm. See the [Dynatrace OpenShift installation guide](https://docs.dynatrace.com/docs/setup-and-configuration/setup-on-k8s/installation/platform-specific-configurations/openshift).

---

## Network Policy Considerations

### Consul Inter-Agent Communication Ports

Consul agents communicate on the following ports. Your OpenShift NetworkPolicy must allow traffic on these ports between Consul components:

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 8300 | TCP | Server ↔ Server, Client → Server | Raft / RPC |
| 8301 | TCP/UDP | All agents (LAN) | Serf LAN gossip |
| 8302 | TCP/UDP | Server ↔ Server (WAN) | Serf WAN gossip |
| 8500 | TCP | HTTP API (internal) | Consul API (metrics, health) |
| 8501 | TCP | HTTPS API (if TLS enabled) | Consul API over TLS |
| 8600 | TCP/UDP | DNS | Consul DNS |

### Dynatrace OneAgent DogStatsD Port

Consul agents send DogStatsD metrics to OneAgent on each node via UDP port 8125. Since Consul pods and OneAgent are on the same node (OneAgent runs as a DaemonSet), traffic stays local to the node.

If you use NetworkPolicy with a default-deny stance, add a rule permitting UDP egress from Consul pods to the node IP on port 8125:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: consul-dogstatsd-egress
  namespace: consul
spec:
  podSelector:
    matchLabels:
      app: consul
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 8125
      # Host network — no ipBlock needed when OneAgent runs on host network
```

### Prometheus Scrape Access

If Dynatrace ActiveGate scrapes the Consul metrics API, allow TCP ingress to port 8500 (or 8501 for TLS) from the ActiveGate pod:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: consul-metrics-ingress
  namespace: consul
spec:
  podSelector:
    matchLabels:
      component: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: dynatrace
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: activegate
      ports:
        - protocol: TCP
          port: 8500
```

---

## Downward API for Node IP (DogStatsD Target)

When Consul pods send DogStatsD metrics to Dynatrace OneAgent on the host, they need the node IP. Use the Kubernetes Downward API to expose this as an environment variable:

```yaml
# In the Consul server StatefulSet or via Helm values
env:
  - name: HOST_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
```

Then reference `$(HOST_IP)` in the Consul telemetry configuration:

```hcl
telemetry {
  dogstatsd_addr = "${HOST_IP}:8125"
}
```

In the Consul Helm chart, use the `server.extraEnvironmentVars` stanza:

```yaml
server:
  extraEnvironmentVars:
    HOST_IP:
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
```

And set the telemetry ConfigMap to use the environment variable interpolation when Consul reads it.

---

## Dynatrace Operator on OpenShift

The recommended deployment method for Dynatrace on OpenShift is via the **Dynatrace Operator**, available through OperatorHub.

### Install via OperatorHub

1. In the OpenShift console: **Operators → OperatorHub → search "Dynatrace"**.
2. Install the Dynatrace Operator in the `dynatrace` namespace.
3. Create a `DynaKube` custom resource:

```yaml
apiVersion: dynatrace.com/v1beta1
kind: DynaKube
metadata:
  name: consul-monitoring
  namespace: dynatrace
spec:
  apiUrl: https://<your-tenant>.live.dynatrace.com/api

  # Deploy OneAgent on every node (required for DogStatsD reception and log tailing)
  oneAgent:
    hostMonitoring:
      enabled: true

  # Deploy ActiveGate for Prometheus scraping and API access
  activeGate:
    capabilities:
      - routing
      - kubernetes-monitoring
      - prometheus-exporter
    resources:
      requests:
        memory: 512Mi
      limits:
        memory: 1Gi
```

### Required RBAC

The Dynatrace Operator service account needs read access to Consul pods and services for entity discovery:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dynatrace-consul-discovery
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "deployments"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dynatrace-consul-discovery
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dynatrace-consul-discovery
subjects:
  - kind: ServiceAccount
    name: dynatrace-kubernetes-monitoring
    namespace: dynatrace
```

---

## Namespace Isolation (Consul Enterprise)

Consul Enterprise supports [administrative namespaces](https://developer.hashicorp.com/consul/docs/enterprise/namespaces) for multi-tenant deployments. When monitoring multi-namespace Consul deployments:

- Each Consul namespace exposes separate service registration metrics under `consul.state.services.<datacenter>` — note this metric is datacenter-scoped, not namespace-scoped in the current telemetry output.
- ACL tokens for the Dynatrace metrics scraper must be granted across all namespaces if you require cross-namespace visibility.
- Log events will include the namespace in the log context when available.

For cross-namespace metrics collection, create an ACL token with a global policy:

```hcl
# dynatrace-metrics-policy.hcl
namespace_prefix "" {
  agent_prefix "" {
    policy = "read"
  }
}
```

---

## Consul Enterprise License on OpenShift

Store the Consul Enterprise license as an OpenShift Secret:

```bash
oc create secret generic consul-ent-license \
  --from-literal=key="<license-string>" \
  -n consul
```

Reference it in the Helm values:

```yaml
global:
  enterpriseLicense:
    secretName: consul-ent-license
    secretKey: key
```

Monitor the license expiry metric (`consul.system.licenseExpiration`) and alert as described in [docs/05-key-metrics-and-alerts.md](./05-key-metrics-and-alerts.md).

---

## OpenShift Routes for Consul UI (Optional)

If you want to access the Consul UI or Consul API from outside the cluster via Dynatrace synthetic monitoring or manual inspection, expose via an OpenShift Route (not a plain Ingress):

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: consul-ui
  namespace: consul
spec:
  to:
    kind: Service
    name: consul-ui
  port:
    targetPort: 8500
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

> **Security:** Restrict access via the Route with OpenShift OAuth or an external IdP. Do not expose the Consul API publicly without authentication.
