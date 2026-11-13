# Allow From NOWAN VLAN Component

This component lets the devices on the `NOWAN` VLAN connect to your `Pod`s.  The cameras are on
this VLAN.

The rule admits these addresses:

- `10.67.0.0/24`, NOWAN.

Without this component, the `deny-all` rule in your `Namespace` drops these connections.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-nowan-vlan
```

## Required Labels

Put the `hogs.tswn.us/nowan-vlan-target` label on each `Pod` that these addresses connect to.  The rule
does not open a path to a `Pod` that does not have the label.

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
        hogs.tswn.us/nowan-vlan-target: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

## The Ports

The rule opens all ports.  Most `Pod`s need fewer.  Add a patch in your overlay that adds a port
list to the rule, and give the patch a `target` with the name `allow-from-nowan-vlan-networkpolicy`.

```yaml
---
- op: add
  path: /spec/ingress/0/ports
  value:
    - port: web
      protocol: TCP
```

Use the name of the container port when the `Pod` gives one.  A `NetworkPolicy` reads the port of
the `Pod` and not the port of the `Service`.  A `Pod` that has no container port with that name
gets nothing from the entry.
