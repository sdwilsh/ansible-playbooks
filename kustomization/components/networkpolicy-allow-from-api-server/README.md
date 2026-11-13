# Allow From API Server Component

This component lets the Kubernetes API server connect to your `Pod`s.  The API server connects to
the `Pod` of an admission webhook, of a conversion webhook, and of an aggregated `APIService`.

The rule admits `10.11.0.101`, the address of node01.  The API server runs on node01 only, and a
connection to a `Pod` on a different node comes from this address.  A connection to a `Pod` on
node01 comes from the address of the local bridge.  kube-router admits that traffic from the local
node without a rule.

This component is the ingress side.  The API server is not a `Pod` in this cluster, so it needs no
egress rule.  For the other direction, use the `networkpolicy-allow-to-api-server` component.

Without this component, the `deny-all` rule in your `Namespace` drops these connections.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-api-server
```

## Required Labels

Put the `hogs.tswn.us/api-server-target` label on each `Pod` that the API server connects to.  The
rule does not open a path to a `Pod` that does not have the label.

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
        hogs.tswn.us/api-server-target: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

## The Ports

The rule opens all ports.  Most `Pod`s need one port only.  Add a patch in your overlay that adds a
port list to the rule, and give the patch a `target` with the name
`allow-from-api-server-networkpolicy`.

```yaml
---
- op: add
  path: /spec/ingress/0/ports
  value:
    - port: webhook-server
      protocol: TCP
```

Use the name of the container port when the `Pod` gives one.  A `NetworkPolicy` reads the port of
the `Pod` and not the port of the `Service`.  A `Pod` that has no container port with that name
gets nothing from the entry.
