# Allow From Prometheus Component

This component lets Prometheus in the `monitoring` namespace read the metrics of your `Pod`s.  A
`Pod` that a `PodMonitor` or a `ServiceMonitor` names usually needs this component, because the
`deny-all` rule in your `Namespace` drops the scrape without it.

A CloudNativePG `Cluster` does not need this component.  The
`networkpolicy-allow-from-prometheus-to-cnpg-cluster` component brings its own rule, and that rule
selects the instance `Pod`s of the `Cluster`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-prometheus
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/prometheus-target` label on your `namespace.yml`.  No rule reads this label
yet.  One egress rule gives Prometheus a path to the other `Namespace`s, in
`kustomization/overlays/prod/monitoring/networkpolicy/allow-from-prometheus.yml`, and that rule
names every `Namespace`.  A future change reads this label there, and gives Prometheus
a path to the marked `Namespace`s only.  Each scraped `Namespace` gets the label on the day that it
gets a `deny-all` rule and this component, so the marked set becomes the full set.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/prometheus-target: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the `hogs.tswn.us/prometheus-target` label on each `Pod` that gives metrics.  The
`NetworkPolicy` drops the scrape of a `Pod` that does not have the label.

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
        hogs.tswn.us/prometheus-target: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

An operator makes the `Pod`s of some workloads, so the overlay has no `Pod` template to patch.
Use the field that the operator gives:

- a `Prometheus` or an `Alertmanager` takes `spec.podMetadata.labels`.
- a CloudNativePG `Cluster` takes `spec.inheritedMetadata.labels`.

## The Port

The rule opens the `metrics` port.  A `NetworkPolicy` reads the port of the `Pod` and not the port
of the `Service`, so `metrics` must be the name of a container port on your `Pod`.  The port that
your `PodMonitor` names must be the same one.

A `ServiceMonitor` names the port of the `Service`.  That `Service` must send the port to a
container port with the same name, or the rule opens nothing.

The `NetworkPolicy` needs a patch in your overlay in two cases.

- your `Pod` gives the port another name.
  `kustomization/overlays/prod/auth/patches/set_prometheus_networkpolicy_ports.yml` shows this
  case.
- your `Pod` gives more than one port.
  `kustomization/overlays/prod/immich/patches/set_prometheus_networkpolicy_ports.yml` shows this
  case.

A port name is read for each `Pod` on its own.  A `Pod` that has no container port with that name
gets nothing from the entry, so one rule can name the ports of every workload in the `Namespace`.
Both patches replace the list, so a patch must name every port that the `Namespace` needs.
