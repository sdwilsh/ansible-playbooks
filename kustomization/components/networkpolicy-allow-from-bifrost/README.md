# Allow From Bifrost Component

This component lets Bifrost send a request to your `Pod`s.  Bifrost is the model gateway of this
cluster, and it is also the broker for the MCP servers.  An MCP server needs this component,
because the `deny-all` rule in your `Namespace` drops the request from Bifrost without it.

An agent never calls your server itself.  It calls Bifrost, and Bifrost calls you, so the agent
needs no credential of its own.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-bifrost
```

## Required Labels

### Namespace

Put the `hogs.tswn.us/bifrost-route` label on your `namespace.yml`.  The egress rule in the
`bifrost` namespace reads it to find your `Namespace`.  Without the label Bifrost has no path to
you, and the component alone gives no result.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    hogs.tswn.us/bifrost-route: "true"
  name: this-is-ignored-but-is-required
```

### Pods

Put the `hogs.tswn.us/bifrost-route` label on each `Pod` that Bifrost reaches.  The `NetworkPolicy`
drops the connection to a `Pod` that does not have the label.

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
        hogs.tswn.us/bifrost-route: "true"
```

Many workloads come from a Helm chart or from a shared component, and you cannot write in those
files.  Add the label with a patch, and give the patch a `target` in your `kustomization.yml`.

## Point Bifrost At Your Server

Bifrost keeps the address of each MCP server in
`kustomization/overlays/prod/bifrost/configmap/config.json`.  Add one entry to
`mcp.client_configs`.  Then give each virtual key that may use the server an entry in
`governance.virtual_keys[].mcp_configs`.  A virtual key with no entry reaches no server.

```json
{
  "connection_string": "http://<name>-svc.<namespace>.svc.cluster.local:<port>/mcp",
  "connection_type": "http",
  "name": "<name>",
  "tools_to_execute": ["*"]
}
```
