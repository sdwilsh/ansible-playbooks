# Allow To API Server Component

This component gives your `Pod`s a path to the Kubernetes API server.  A `Pod` that reads or writes
a Kubernetes resource needs this path.  A `Pod` that only serves traffic does not.

The rule opens two addresses.  The first is `172.17.0.1`, the `ClusterIP` of the
`kubernetes.default.svc` `Service`, on port `443`.  The second is `10.11.0.101`, the address of
node01, on port `6443`.  A client reaches the API server at one address or the other, so the rule
opens both.

This component is the egress side, and the egress side is the only control.  The API server is not
a `Pod` in this cluster, so a `NetworkPolicy` cannot filter the other end.

## The CloudNativePG Path

The `cnpg-backup` component brings this component in, and it replaces the `podSelector` with a list
that names the `database` component and the `wait-for-backup` component.  Twelve overlays get the
rule that way.

Two rules follow from that.

- do not add this component to an overlay that has `cnpg-backup`.  Two copies of the same
  `NetworkPolicy` stop the build with `may not add resource with an already registered id`.
- the `hogs.tswn.us/api-server-client` label does nothing in such an overlay.  `cnpg-backup`
  replaces the whole `podSelector`, so no rule reads the label there.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-api-server
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/api-server-client` label on your `namespace.yml`.  No rule reads this label.
It is a marker for a person who reads the overlay, and it shows which `Namespace`s hold a client of
the API server.  The other components in this group use the same label on the `Namespace`, so keep
it here as well.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/api-server-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that calls the API server.  The `NetworkPolicy` drops the
connection from a `Pod` that does not have the label.

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
        hogs.tswn.us/api-server-client: "true"
```

## An Operator That Makes The Pods

An operator makes the `Pod`s of some workloads, so the overlay has no `Pod` template to patch.  Use
the field that the operator gives, such as `spec.podMetadata.labels` on a `Prometheus`, or
`spec.inheritedMetadata.labels` on a CloudNativePG `Cluster`.

An operator that gives no such field needs a patch on the rule instead.
`kustomization/overlays/prod/kube-amd-gpu/patches/keep_api_server_networkpolicy_wide.yml` shows
this case: the AMD GPU operator makes the `Pod`s of the device plugin and of the node labeller, and
its `DeviceConfig` CRD has no field for the labels of those `Pod`s.
