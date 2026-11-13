# Allow From Redis Operator Component

This component lets the Redis operator in the `redis` namespace connect to your Redis `Pod`s.  The
operator connects to each `Pod` by its IP address on port `6379`, and on the `sentinel` port of a
sentinel `Pod`.  It does this for a `RedisReplication` and for a `RedisSentinel`.  It connects to
the `Pod` of a standalone `Redis` only to apply `spec.redisConfig.dynamicConfig`.  A standalone
`Redis` that does not set this field does not need this component.

The operator side of this path is in `kustomization/overlays/prod/redis/networkpolicy/`.

Without this component, the `deny-all` rule in your `Namespace` drops these connections.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/networkpolicy-allow-from-redis-operator
```

## Required Labels

None.  The operator puts the `redis_setup_type` label on each `Pod` that it makes, and the rule
selects the `Pod`s that have this label.
