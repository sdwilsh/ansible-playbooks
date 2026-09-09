# Allow To LLDAP Component

This component gives your `Pod`s a path to [lldap](https://github.com/lldap/lldap) in the `auth`
namespace.  lldap holds the users and the groups of this cluster.  A client binds to it over LDAPS
and reads those records.

This component opens the egress side, in your `Namespace`.  lldap has an ingress rule that must
admit your `Pod`s as well.  That rule is `allow-to-lldap-from-consumers-networkpolicy`, in
`kustomization/overlays/prod/auth/networkpolicy/`.  The rule looks for a label on your `Namespace`,
and for the same label on each `Pod`.  The `NetworkPolicy` drops the connection when one of the two
labels is absent.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the lldap `Service`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-lldap
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/lldap-client` label on your `namespace.yml`.  lldap selects the clients with
this label, and not with a name.  lldap does not change when a new client starts.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/lldap-client: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the same label on each `Pod` that binds to the directory.  The `NetworkPolicy` drops a
connection from a `Pod` that does not have the label, and the label on the `Namespace` does not
change that result.

The label does two things.  The ingress rule in the `auth` namespace looks for it.  The egress rule
in this component uses it to select the `Pod`s that get the path out.

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
        hogs.tswn.us/lldap-client: "true"
```

## Point A Client At The Directory

Bind to the lldap `Service` over LDAPS.  The `Service` listens on port `636`, and it sends the
connection to port `6360` on the `Pod`.  The `NetworkPolicy` names that port `ldaps`, because a
`NetworkPolicy` reads the port of the `Pod` and not the port of the `Service`.

This rule opens the `ldaps` port only.  lldap also gives plain LDAP on port `389`, and a web
interface on port `80`.  This rule opens neither of them.

Each client has a different name for the variable.  opencloud uses `OC_LDAP_URI`, in
`kustomization/overlays/prod/opencloud/patches/opencloud/add_config.yml`.

```yaml
env:
  - name: OC_LDAP_URI
    value: ldaps://lldap-svc.auth.svc.cluster.local:636
```
