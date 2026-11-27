# egress-proxy

This overlay runs [Iron Proxy](https://github.com/paradigmxyz/iron-proxy) instances.  An instance
lets the `Pod`s of one client reach a short list of public hosts, methods and paths.  The proxy
blocks all other requests.  A `NetworkPolicy` can name an address but not a host, and most public
APIs have no fixed addresses.  Without the proxy, the client needs the
`networkpolicy-allow-to-internet` component, which opens the whole internet.

## How an instance works

Each client gets its own instance.  An instance has two proxy `Pod`s, an allowlist, a CA chain, a
`Service` and an ingress rule.  The tunnel listener does not authenticate its clients, so two clients of one
instance would get the union of their lists.  The ingress rule admits only the `Pod`s in the
`Namespace` of the client that have the label `hogs.tswn.us/egress-proxy-client: <instance>`.  A
`Pod` has only one value for this label, so it can use only one instance.

The two `Pod`s of an instance run on different nodes.  A rollout starts a new `Pod` before it
stops an old one, and a `PodDisruptionBudget` lets a drain evict one `Pod` at a time.  A `Pod` keeps
no state that the other `Pod` needs, so each `Pod` can serve each request.

The proxy reads the requests inside each TLS connection, so that it can check the method and the
path.  To do this, it signs a certificate for each host with an intermediate CA.  The intermediate
key stays in this `Namespace`.  The root CA of each instance and its `ClusterIssuer` are in the
`cert-manager` overlay, because a `ClusterIssuer` reads its CA from that `Namespace` only.  The
client gets a `Certificate` from the `ClusterIssuer`, and it trusts the `ca.crt` key of its
`Secret`.  Nobody copies a certificate.  The name constraints of the root and of the intermediate
permit only the allowlist hosts and no IP address.  So a leaked proxy key, or a certificate that
another `Namespace` gets from the `ClusterIssuer`, cannot act as another host to the client.

## Add an instance for a new client

1. Write `<client>/egressproxy.yml`.  It has the shape of a Kubernetes resource, but no
   kustomization reads it.  Set `metadata.name` to `<client>`, `spec.client.namespace` to the
   `Namespace` of the client, and `spec.rules` to the allowlist.  Do not write the `CONNECT`
   rules.
2. Run `just generate-egress-proxy`.  It writes the instance in
   `kustomization/components/codegen-egress-proxy-prod/<client>/`, and the root CA and the
   `ClusterIssuer` in `kustomization/components/codegen-egress-proxy-ca-prod/`.  It adds the
   instance to the `resources` of both components.  This overlay and the `cert-manager` overlay
   include these components.

Do not edit the generated files.  CI runs `just egress-proxy-codegen-check`.  It fails when the
generated files are not the output of the codegen.

Merge the changes in this order.  First, deploy a client build that reads the proxy settings and
trusts the CA file.  A client that uses `HTTPS_PROXY` but does not trust the CA fails each TLS
connection through the proxy, and the proxy logs no blocked request.  Then merge the `cert-manager`
and `egress-proxy` changes, and wait until the proxy `Pod`s are ready.  Then merge the client
change.  The client `Pod` does not start before its CA `Secret` exists.

## Allowlist reference

`<instance>/egressproxy.yml` holds the allowlist.  The codegen copies each rule as it is into the
Iron Proxy configuration of the instance.  Before the first rule of each host, it adds a rule with
`methods: [CONNECT]`.  It writes each host in the name constraints of the root and of the
intermediate CA.  For `*.example.com`, it writes `example.com`, which also permits each name
below it.

`kustomization/components/egress-proxy-instance/` holds the resources of each instance.  kustomize
adds the `namePrefix` of an instance to each name.  Its `kustomizeconfig.yml` also adds it to the
names of the CA `Secret` and of the `ClusterIssuer`.

A request must match one rule.  A rule can match these fields:

- `host`: a name, or `*.example.com` for `example.com` and each name below it.
- `methods`: a list of methods.  Without `methods`, the rule matches each method.
- `paths`: a list of patterns for the path.  Without `paths`, the rule matches each path.  A rule
  cannot match the query string, a header or the body.

A path pattern uses these wildcards:

- `?*` matches one segment with one or more characters.  `/branches/?*` matches `/branches/v5`.
  It does not match `/branches/` or `/branches/a/b`.
- `*` at the end, after a `/`, matches the prefix and each path below it.  `/branches/*` matches
  `/branches`, `/branches/v5` and `/branches/a/b`.
- `*` at another position matches zero or more characters in one segment.

A client opens a tunnel with `CONNECT <host>:443`.  The proxy checks the `CONNECT` against the
rules with an empty path.  Thus each host needs its own rule with `methods: [CONNECT]` and no
`paths`, and the codegen adds it.  The proxy then checks each request in the tunnel against the
other rules.

With `spec.warn: true` in `egressproxy.yml`, the proxy logs each request that no rule matches
with `"action":"warn"`, and it does not block the request.  Use it only for a short test to find
the requests of a new client.  Warn mode also lets a `CONNECT` go to any host.
