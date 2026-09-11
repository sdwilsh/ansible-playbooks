# Allow To Internet Component

This component gives your `Pod`s a path out of the cluster.  A `Pod` that reads a public API needs
this path.  A `Pod` that pulls a catalogue, or that sends a message to a service on the internet,
needs it as well.

The rule opens port `80` and port `443` to `0.0.0.0/0`.  It removes the private ranges and the
link-local range from that block, so the path goes to the internet only.  A `Pod` cannot reach
another `Namespace`, the nodes, or the home network through this rule.

This component opens the egress side, in your `Namespace`.  This side is the only network control.
The other end is not a `Pod` in this cluster, so a `NetworkPolicy` cannot filter it.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the public service.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-internet
```

## Required Labels

Put the `hogs.tswn.us/internet-client` label on each `Pod` that goes out of the cluster.  A `Pod`
that does not have the label gets no rule from this component, and the `deny-all` rule in your
`Namespace` then drops the connection.

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
        hogs.tswn.us/internet-client: "true"
```

## The Ports

The rule opens port `80` and port `443` only.  A `Pod` that speaks another protocol to the
internet, such as SMTP or NTP, needs a rule in your overlay.  This component does not give one.

The rule names port numbers and not port names.  A name has nothing to resolve against here.
