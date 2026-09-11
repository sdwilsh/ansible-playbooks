# Allow To Loki Component

This component gives your `Pod`s a path to [Loki](https://grafana.com/oss/loki/) in the
`monitoring` namespace.  Loki holds the logs of this cluster.  A `Pod` that writes logs to Loki
uses this path, and a `Pod` that reads them uses it as well.

This component opens the egress side, in your `Namespace`.  Your `Namespace` needs the component
only when it has a `deny-all` rule.  Loki has an ingress rule that must admit your `Pod`s in each
case.  That rule is `allow-to-loki-networkpolicy`, in
`kustomization/overlays/prod/monitoring/networkpolicy/`.  The rule looks for a label on your
`Namespace`, and for the same label on each `Pod`.  The `NetworkPolicy` drops the connection when
one of the two labels is absent.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the Loki `Service`.

A `Pod` that uses the network of the node does not need this component.  A `NetworkPolicy` does not
apply to such a `Pod`, and the ingress rule in the `monitoring` namespace names the address of each
node instead.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-loki
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/loki-client` label on your `namespace.yml`.  Loki selects the clients with
this label, and not with a name.  Loki does not change when a new client starts.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/loki-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that reads or writes logs.  The `NetworkPolicy` drops a connection
from a `Pod` that does not have the label, and the label on the `Namespace` does not change that
result.

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
        hogs.tswn.us/loki-client: "true"
```

## Point A Client At Loki

The rule opens port `3100` on each `Pod` of Loki.  A client that writes logs calls the distributor,
and a client that reads them calls the query frontend.  The rule covers both, because it selects
each `Pod` of Loki.

Each client has a different form.  The alloy of unifi-syslog writes, in
`kustomization/overlays/prod/unifi-syslog/configmap/loki.alloy`.

```hcl
loki.write "default" {
  endpoint {
    url = "http://loki-distributor.monitoring.svc.cluster.local:3100/loki/api/v1/push"
  }
}
```

crowdsec reads, in `kustomization/overlays/prod/crowdsec/configmap/acquis.d/traefik.yaml`.

```yaml
source: loki
url: http://loki-query-frontend.monitoring.svc.cluster.local:3100/
```
