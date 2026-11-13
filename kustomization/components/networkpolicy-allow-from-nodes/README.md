# Allow From Nodes Component

This component lets the nodes of the cluster connect to your `Pod`s.  A node connects with its
own address when a process on the node starts the connection, such as the container runtime
when it pulls an image.  A `Pod` that uses the network of the node does the same.

The rule names each node.  Other hosts on the `SERVICES` VLAN do not get a path from this
component.  When you add a node, add its address here.

The rule admits these addresses:

- `10.11.0.101/32`, node01, on SERVICES.
- `10.11.0.104/32`, worker01, on SERVICES.
- `10.11.0.105/32`, worker02, on SERVICES.
- `10.11.0.106/32`, worker03, on SERVICES.
- `10.11.0.120/32`, gpuworker01, on SERVICES.
- `10.11.0.121/32`, gpuworker02, on SERVICES.

Without this component, the `deny-all` rule in your `Namespace` drops these connections.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-nodes
```

## Required Labels

Put the `hogs.tswn.us/nodes-target` label on each `Pod` that these addresses connect to.  The rule
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
        hogs.tswn.us/nodes-target: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

## The Ports

The rule opens all ports.  Most `Pod`s need fewer.  Add a patch in your overlay that adds a port
list to the rule, and give the patch a `target` with the name `allow-from-nodes-networkpolicy`.

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
