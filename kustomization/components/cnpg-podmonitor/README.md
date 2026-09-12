# CloudNativePG PodMonitor Component

This component gives Prometheus a `PodMonitor` for the CloudNativePG `Cluster` in your
`Namespace`.  Prometheus then collects the metrics of the database: the replication lag, the count
of the connections, the state of the WAL and the result of each backup.

The component reads the name of the `Cluster` and writes it in each of the four fields that need
it: the name of the `PodMonitor`, the selector, the `Secret` of the certificate authority, and the
name of the server for TLS.  You give no name yourself.

The `PodMonitor` keeps a `kustomize.hogs.tswn.us/cnpg-podmonitor` label.  kustomize finds the `PodMonitor`
with it, and the label therefore stays in the manifest.  Nothing at run time reads the label.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/cnpg-backup
  - ../../../components/cnpg-podmonitor
```

## One Cluster For Each Namespace

Use this component only when your `Namespace` has one `Cluster`.  The `replacements` finds the
`Cluster` by kind, so two of them make the source of the name unclear.

## The Network Path

Prometheus must have a path to the `Pod`s of your `Cluster`.  Without it the `deny-all` rule drops
the connection, and the target of the `PodMonitor` shows as down.

Your `Namespace` usually gets this path from the
`networkpolicy-allow-from-prometheus-to-cnpg-cluster` component.
