# Allow From Traefik Component

This component lets [Traefik](https://traefik.io) send a request to your `Pod`s.  Traefik is the
ingress of this cluster.  A `Pod` that answers a public name needs this component, because the
`deny-all` rule in your `Namespace` drops the request from Traefik without it.

This component is for the direction into your `Namespace`.  It is not for a `Pod` that calls out
through Traefik.  Use the `networkpolicy-allow-to-traefik` component for that direction.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-traefik
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/traefik-route` label on your `namespace.yml`.  No rule reads this label yet.
The `traefik` namespace has no `NetworkPolicy` at all, because the consumers and the providers of
Traefik have not all moved to this scheme.  A future change adds a `deny-all` rule there, and the
egress rule that goes with it reads this label to find your `Namespace`.  Put the label on now, and
your client needs no change on that day.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/traefik-route: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the `hogs.tswn.us/traefik-route` label on each `Pod` that Traefik reaches.  The
`NetworkPolicy` drops the connection to a `Pod` that does not have the label.

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
        hogs.tswn.us/traefik-route: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

An operator makes the `Pod`s of some workloads, so the overlay has no `Pod` template to patch.
Use the field that the operator gives:

- a `Prometheus` or an `Alertmanager` takes `spec.podMetadata.labels`.
- a CloudNativePG `Cluster` takes `spec.inheritedMetadata.labels`.

## The Port

The rule opens the `web` port.  A `NetworkPolicy` reads the port of the `Pod` and not the port of
the `Service`, so `web` must be the name of a container port on your `Pod`.

The `NetworkPolicy` needs a change in your overlay when your `Pod` gives that port another name, or
when Traefik reaches more than one port.  The repository does this in two ways:

- a `replacements` block reads the name of the container port from the workload, and writes it over
  the `web` entry.  `kustomization/overlays/prod/forgejo/kustomization.yml` shows this way.
- a patch adds more entries to the port list.
  `kustomization/overlays/prod/homeassistant/patches/add_traefik_networkpolicy_ports.yml` shows
  this way: Traefik reaches `frigate` on the `web` port, `mosquitto` on the `mqtt` port, and the
  database on the `postgresql` port.

A port name is read for each `Pod` on its own.  A `Pod` that has no container port with that name
gets nothing from the entry, so one rule can name the ports of every workload in the `Namespace`.
