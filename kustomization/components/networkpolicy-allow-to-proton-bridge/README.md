# Allow To Proton Bridge Component

This component gives your `Pod`s a path to the
[Proton Mail Bridge](https://proton.me/mail/bridge) in the `proton-mail` namespace.  The bridge
gives SMTP and IMAP in the cluster, and it uses HTTPS to Proton.  A `Pod` that sends or reads mail
uses this path.

This component opens the egress side, in your `Namespace`.  The `proton-mail` namespace has no
`deny-all` rule yet, so nothing reads the label on the `Namespace` at this time.  A future change
adds that rule, and the ingress rule that goes with it reads the label.  The bridge is a normal
workload in the pod network, so that rule selects its clients in the same way that lldap does
today.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the bridge `Service`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-proton-bridge
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/proton-bridge-client` label on your `namespace.yml`.  No rule reads this
label yet, but a future change adds an ingress rule in the `proton-mail` namespace that does.  Put
the label on now, and your client needs no change on that day.  Until then the label shows which
`Namespace`s use the bridge.  The person who writes that rule must first read the list of
`Namespace`s that carry the label, because a marker becomes a grant on that day.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/proton-bridge-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that sends or reads mail.  The `NetworkPolicy` drops a connection
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
        hogs.tswn.us/proton-bridge-client: "true"
```

## Point A Client At The Bridge

The bridge listens on port `25` for SMTP, and on port `143` for IMAP.  This rule opens both ports,
so a client that only sends mail also gets the path to read the mailbox.  The bridge accepts
STARTTLS on both ports, and it adds TLS on the path from the cluster to Proton.

Each client has a different name for the variable.  lldap uses `LLDAP_SMTP_OPTIONS__SERVER` and
`LLDAP_SMTP_OPTIONS__PORT`.

```yaml
env:
  - name: LLDAP_SMTP_OPTIONS__SERVER
    value: proton-bridge-svc.proton-mail.svc.cluster.local
  - name: LLDAP_SMTP_OPTIONS__PORT
    value: "25"
```
