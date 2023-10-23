# Unifi Controller Component

This will deploy the [Unifi Network Application](https://github.com/linuxserver/docker-unifi-network-application), and
assumes you are using [Traefik Proxy](https://traefik.io/traefik).

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/unifi-network-application
```

See below for additionally required patches and secrets.

## Required Patches

### Set Ingress Host

#### `kustomization.yml`

```yaml
patches:
  - path: patches/set_una_ingress_host.yml
    target:
      kind: Ingress
      name: una-ingress
```

#### `patches/set_una_ingress_host.yml`

```yaml
---
- op: add
  path: /spec/rules/0/host
  value: unifi.example.com
```

### Add ServersTransport to Service

#### `kustomization.yml`

```yaml
patches:
  - path: patches/add_una_svc_serverstransport.yml
    target:
      kind: Service
      name: una-unifi-svc
```

#### `patches/add_una_svc_serverstransport.yml`

The format of the annotation value is: `<deployed-namespace>-una-unifi-serverstransport@kubernetescrd`.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  annotations:
    traefik.ingress.kubernetes.io/service.serverstransport: unifi-una-unifi-serverstransport@kubernetescrd
  name: this-is-ignored-but-is-required
```

## Required Secrets

### `una-secret`

This needs to have the following keys defined:
 - `MONGO_PASS`

You can include additional keys as well for further configuration.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: una-secret
stringData:
  MONGO_PASS: ...
```
