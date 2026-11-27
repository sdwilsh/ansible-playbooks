# Allow To Egress Proxy Component

This component gives your `Pod`s a path to one [Iron Proxy](https://github.com/paradigmxyz/iron-proxy)
instance in the `egress-proxy` namespace.  The proxy allows a list of public hosts, and it blocks
the other requests.  Use it when a `Pod` must reach a small set of public hosts that have no fixed
addresses.  A `NetworkPolicy` cannot name a host, so `networkpolicy-allow-to-internet` would open
the whole internet.

This component opens the egress side, in your `Namespace`, to your instance only.  Each instance has
an ingress rule in `kustomization/overlays/prod/egress-proxy/<instance>/`.  That rule names your
`Namespace` and your label value, so other `Pod`s cannot use your instance.  To add an instance, see
the `egress-proxy` overlay README.

Your `Namespace` also needs the `networkpolicy-allow-to-coredns` component.  Without it the client
cannot resolve the name of the proxy `Service`.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-to-egress-proxy
patches:
  - path: patches/set_egress_proxy_instance.yml
    target:
      kind: NetworkPolicy
      name: allow-to-egress-proxy-networkpolicy
```

## Set The Instance

The rule in this component selects no `Pod` until you set the name of your instance.  Set it in the
`podSelector` and in the `podSelector` of the peer.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: this-is-ignored-but-is-required
spec:
  egress:
    - ports:
        - port: tunnel
          protocol: TCP
      to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: egress-proxy
          podSelector:
            matchLabels:
              app.kubernetes.io/instance: <instance>
              app.kubernetes.io/name: iron-proxy
  podSelector:
    matchLabels:
      hogs.tswn.us/egress-proxy-client: <instance>
```

The rule has one name, so a `Namespace` can use this component for one instance only.  A second
client in the same `Namespace` needs a copy of the rule with its own name.

## Required Labels

Put the `hogs.tswn.us/egress-proxy-client` label on each `Pod` that uses the proxy.  The value is
the name of your instance.  The egress rule in this component and the ingress rule of the instance
both look for it.

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
        hogs.tswn.us/egress-proxy-client: <instance>
```

## Point A Client At The Proxy

Set `HTTPS_PROXY` and `HTTP_PROXY` to the tunnel port of your instance.  Set `NO_PROXY` to the
names and ranges that must not go through the proxy.  For example, `tswn.us` keeps Traefik and
Authelia off the proxy, and `172.17.0.0/16` is the `Service` range.  Give each name with and without
a leading dot, because some clients read a name without a dot as an exact match.

Each client reads `NO_PROXY` with its own parser, so the list is per client.  The example below is
for a Go client.  disc-ripper refuses a CIDR range or a port in `NO_PROXY`, and it stops at start.
Read how the client parses the list before you copy it.

The proxy reads each TLS connection, so a client that does not trust its CA fails.  Add a
`Certificate` from the `ClusterIssuer` of your instance.  Mount only the `ca.crt` key of its
`Secret`, and make the client trust it.  For a Go client, set `SSL_CERT_DIR` to its directory.  A Go
client then trusts the CA and the system CAs.  Other clients need their own setting.  The client
reads the CA at start only.  Before the `Secret` exists, the `Pod` does not start.

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: egress-proxy-ca-certificate
spec:
  issuerRef:
    kind: ClusterIssuer
    name: <instance>-iron-proxy-ca-clusterissuer
  privateKey:
    algorithm: ECDSA
    size: 256
  secretName: egress-proxy-ca-secret
  uris:
    - urn:hogs.tswn.us:egress-proxy-ca:<instance>
```

```yaml
env:
  - name: HTTPS_PROXY
    value: http://<instance>-iron-proxy-svc.egress-proxy.svc.cluster.local:8080
  - name: HTTP_PROXY
    value: http://<instance>-iron-proxy-svc.egress-proxy.svc.cluster.local:8080
  - name: NO_PROXY
    value: tswn.us,.tswn.us,cluster.local,.cluster.local,svc,.svc,172.17.0.0/16
  - name: SSL_CERT_DIR
    value: /etc/egress-proxy-ca
```
