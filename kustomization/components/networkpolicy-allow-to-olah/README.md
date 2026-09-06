# Allow To Olah Component

This component gives your pods a path to the [olah](https://github.com/vtuber-plan/olah) cache in
the `olah` namespace.  olah is a cache for [Hugging Face](https://huggingface.co).  olah keeps a
model on disk after one workload downloads it.  The next workload reads that model from the disk.

This component opens the egress side, in your namespace.  olah has an ingress rule that must admit
your pods as well.  That rule is `allow-to-olah-from-consumers-networkpolicy`, in
`kustomization/overlays/prod/olah/networkpolicy/`.  The rule looks for a label on your namespace,
and for the same label on each pod.  The NetworkPolicy drops the connection when one of the two
labels is absent.  olah itself accepts every request that arrives, so the two rules are the only
control.

Your namespace also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the olah `Service`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-olah
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/olah-client` label on your `namespace.yml`.  olah selects the clients with
this label, and not with a name.  olah does not change when a new client starts.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/olah-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each pod that reads the cache.  The NetworkPolicy drops a connection from a
pod that does not have the label, and the label on the namespace does not change that result.

The label does two things.  The ingress rule in the olah namespace looks for it.  The egress rule
in this component uses it to select the pods that get the path out.

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
        hogs.tswn.us/olah-client: "true"
```

## Point A Client At The Cache

Set the Hugging Face endpoint to the olah `Service`.  The client then reads the models through the
cache, and not from `huggingface.co`.

The endpoint uses HTTP.  A client that sets `HF_TOKEN` sends that token to olah in clear text, and
olah sends the token to `huggingface.co`.  Use a token for a private repository only when that
risk is acceptable.

```yaml
env:
  - name: HF_ENDPOINT
    value: http://olah-svc.olah.svc.cluster.local:8090
```
