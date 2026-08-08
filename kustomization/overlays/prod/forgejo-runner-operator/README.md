# forgejo-runner-operator Overlay

Deploys the [forgejo-runner-operator](https://code.tswn.us/marinatedconcrete/forgejo-runner-operator) controller: the CRDs (`Connection`, `Worker`), the manager `Deployment`, its RBAC, and the validating webhook. The actual runner workloads live in `forgejo-runners-privileged` and `forgejo-runners-restricted`.

## Pod Security Standard

Runs under `restricted`. The controller itself never executes untrusted CI code, so it doesn't need the elevated capabilities the worker namespaces do.

## RBAC Scope

`manager-cache-role` is cluster-scoped read access (informer cache for controller-runtime), broader than the two namespaces this operator actually manages. `manager-role` in each runner namespace grants `escalate`/`bind` so the operator can provision per-`Worker` RBAC dynamically. Both are a real concentration of privilege if the operator itself is ever compromised, but neither is reachable from a compromised job pod — there's no NetworkPolicy allowing ingress into this namespace from the runner namespaces.

## Webhook Coverage

Only `Connection` has a validating webhook rule (`failurePolicy: Ignore`); `Worker` has none. Not currently exploitable — nothing but this controller's own `ServiceAccount` can create either CRD — but worth closing before any self-service `Worker` creation path exists.
