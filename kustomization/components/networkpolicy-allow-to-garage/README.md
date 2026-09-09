# Allow To Garage Component

This component gives your `Pod`s a path to [Garage](https://garagehq.deuxfleurs.fr) in the `garage`
namespace.  Garage holds the S3 buckets of this cluster.

This component opens the egress side, in your `Namespace`.  This side is the only network control.
The Garage `DaemonSet` runs with `hostNetwork`, so the `Pod`s of Garage use the network of the
node.  A `NetworkPolicy` does not apply to a `Pod` that uses the network of the node.  A `deny-all`
rule in the `garage` namespace gives no second control here, and an ingress rule there does not
filter this traffic.  Use a firewall on the node for that.

Because Garage uses the network of the node, a client reaches Garage at the address of the node,
and not at an address in the pod network.  This is why the rule names the nodes as well as the
`Pod`s.  A new node needs a new entry here.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the Garage `Service`.

A client can also reach a bucket at `https://s3.tswn.us`, which the Garage `Ingress` serves
through Traefik.  That path needs the `networkpolicy-allow-to-traefik` component, and not this
one.  Manyfold reads its models that way.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-garage
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/garage-client` label on your `namespace.yml`.  No rule reads this label.  It
is a marker for a person who reads the overlay, and it shows which `Namespace`s use a bucket.  The
other components in this group use the same label on the `Namespace`, so keep it here as well.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/garage-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that reads or writes a bucket.  The `NetworkPolicy` drops a
connection from a `Pod` that does not have the label.

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.  The
Loki patch in `kustomization/overlays/prod/monitoring/kustomization.yml` shows a `labelSelector`
target, which puts the label on many workloads of one chart at the same time.

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
        hogs.tswn.us/garage-client: "true"
```

## Point A Client At The Buckets

Garage gives the S3 API on port `3900`.  This rule opens that port only.

A client must use the path style.  The `root_domain` of Garage is `.s3.garage.tld`, and the name
of the `Service` in the cluster does not end with that name.  Forgejo sets `MINIO_BUCKET_LOOKUP`
to `path`, and Loki sets `s3ForcePathStyle` to `true`.

Each client has a different name for the variable.  Forgejo uses `MINIO_ENDPOINT`, in
`kustomization/overlays/prod/forgejo/values.yml`.  Loki uses `endpoint`, in
`kustomization/overlays/prod/monitoring/loki-values.yml`.

```yaml
env:
  - name: MINIO_ENDPOINT
    value: garage.garage.svc.cluster.local:3900
```
