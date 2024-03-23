# Authelia Component

This will deploy [Authelia](https://www.authelia.com/), and assumes you are using
[Traefik Proxy](https://traefik.io/traefik).

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/authelia
```

See below for additionally required patches and secrets.

## Required Patches

### Middleware Address

#### `kustomization.yml`

```yaml
patches:
  - path: patches/set_authelia_middleware_address.yml
    target:
      kind: Middleware
      name: forwardauth-authelia-middleware
```
 
### Ingress Host

#### `kustomization.yml`

```yaml
patches:
  - path: patches/change_authelia_ingress_host.yml
    target:
      kind: Ingress
      name: authelia-ingress
```

#### `patches/change_authelia_ingress_host.yml`

```yaml
---
- op: add
  path: /spec/rules/0/host
  value: authelia.example.com
```

### Additional Configuration

This component only provides configuration for [logging](https://www.authelia.com/configuration/miscellaneous/logging/)
and [telemetry](https://www.authelia.com/configuration/telemetry/introduction/).  Everything else should be configured
in a `ConfigMap`.

#### `kustomization.yml`

```yaml
configMapGenerator:
  - name: authelia-configmap
    files:
      - configmap/authelia-config.yml
patches:
```

#### `patches/set_authelia_configuration.yml`

```yaml
---
- op: add
  path: /spec/template/spec/volumes/-
  value:
    configMap:
      name: authelia-configmap
    name: prod-configuration
- op: add
  path: /spec/template/spec/containers/0/volumeMounts/-
  value: 
    mountPath: /config/prod
    name: prod-configuration
    readOnly: true
- op: add
  path: /spec/template/spec/containers/0/args/-
  value: --config
- op: add
  path: /spec/template/spec/containers/0/args/-
  value: /config/prod/authelia-config.yml
```

## Required Secrets

### `authelia-config-secret`

This needs to have the following keys defined:
 - [`jwt_secret`](https://www.authelia.com/configuration/miscellaneous/introduction/#jwt_secret)
 - [`session_secret`](https://www.authelia.com/configuration/session/introduction/#secret)
 - [`storage_encryption_key`](https://www.authelia.com/configuration/storage/introduction/#encryption_key)

You can include additional keys as well for further configuration.  This secret will be mounted at `/secrets` in the
Authelia container.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: authelia-config-secret
stringData:
  jwt_secret: ...
  session_secret: ...
  storage_encryption_key: ...
```
