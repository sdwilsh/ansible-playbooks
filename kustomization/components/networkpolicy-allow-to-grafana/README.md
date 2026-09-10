# Allow To Grafana Component

This component gives your `Pod`s a path to [Grafana](https://grafana.com) in the `monitoring`
namespace.  Grafana holds the dashboards of this cluster, and it gives a proxy to each datasource.
A `Pod` that reads a dashboard, or that reads Loki or Prometheus through the proxy, uses this
path.

This component opens the egress side, in your `Namespace`.  Grafana has an ingress rule that must
admit your `Pod`s as well.  That rule is `allow-to-grafana-networkpolicy`, in
`kustomization/overlays/prod/monitoring/networkpolicy/`.  The rule looks for a label on your
`Namespace`, and for the same label on each `Pod`.  The `NetworkPolicy` drops the connection when
one of the two labels is absent.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the Grafana `Service`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-grafana
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/grafana-client` label on your `namespace.yml`.  Grafana selects the clients
with this label, and not with a name.  Grafana does not change when a new client starts.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/grafana-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that calls Grafana.  The `NetworkPolicy` drops a connection from a
`Pod` that does not have the label, and the label on the `Namespace` does not change that result.

The label does two things.  The ingress rule in the `monitoring` namespace looks for it.  The
egress rule in this component uses it to select the `Pod`s that get the path out.

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: this-is-ignored-but-is-required
spec:
  template:
    metadata:
      labels:
        hogs.tswn.us/grafana-client: "true"
```

## Point A Client At Grafana

Each client has a different name for the variable.  grafana-mcp uses `GRAFANA_URL`, in
`kustomization/overlays/prod/grafana-mcp/kustomization.yml`.

```yaml
env:
  - name: GRAFANA_URL
    value: http://grafana.monitoring.svc.cluster.local
```
