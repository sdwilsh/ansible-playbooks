# Allow To Traefik Component

This component gives your `Pod`s a path to [Traefik](https://traefik.io) in the `traefik`
namespace.  Traefik is the ingress of this cluster.  A `Pod` uses this path when it must call a
service by its public name, and not by the name of a `Service` in the cluster.

This component opens the egress side, in your `Namespace`.  The `traefik` namespace has no
`deny-all` rule yet, so nothing reads the label on the `Namespace` at this time.  A future change
adds that rule, and the ingress rule that goes with it reads the label.  Traefik is a normal
workload in the pod network, so that rule selects its clients in the same way that lldap does
today.

The rule opens two paths, and a client needs both.  A `Pod` that resolves a public name gets
`10.11.1.64`, the load balancer address of the Traefik `Service`, so the first path names that
address.  The connection then goes to a Traefik `Pod`, so the second path names the `Pod`s.

This rule opens the `websecure` entrypoint only.  That entrypoint is port `8443` on the Traefik
`Pod`, and port `443` on the Traefik `Service`.  The two paths give the port in two forms for this
reason: the path to the `Pod`s names the port `websecure`, because a `NetworkPolicy` reads the port
of the `Pod`, and the path to the load balancer address gives the number `443`.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the public name.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-traefik
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/traefik-client` label on your `namespace.yml`.  No rule reads this label yet,
but a future change adds an ingress rule in the `traefik` namespace that does.  Put the label on
now, and your client needs no change on that day.  Until then the label shows which `Namespace`s
call a public name.  The person who writes that rule must first read the list of `Namespace`s that
carry the label, because a marker becomes a grant on that day.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/traefik-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that calls a public name.  The `NetworkPolicy` drops a connection
from a `Pod` that does not have the label.

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
        hogs.tswn.us/traefik-client: "true"
```

## Point A Client At The Ingress

Give the client the public name of the service, and not the name of a `Service` in the cluster.
The client then goes out through Traefik, and Traefik applies the same middlewares and the same
certificate that an external client gets.

Each client has a different name for the variable.  opencloud uses `OC_OIDC_ISSUER` for the
address of Authelia, in
`kustomization/overlays/prod/opencloud/patches/opencloud/add_config.yml`.  Forgejo uses
`ROOT_URL`, in `kustomization/overlays/prod/forgejo/values.yml`.

```yaml
env:
  - name: OC_OIDC_ISSUER
    value: https://auth.tswn.us
```

## A Note On The Direction

This component is for a `Pod` that calls out through Traefik.  It is not for a `Pod` that Traefik
calls.  Use the `networkpolicy-allow-from-traefik` component for that direction.
