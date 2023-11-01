# Mosquitto Component

This will deploy the [Mosquitto](https://mosquitto.org/). This runs as as the `mosquitto` user
from the [`mosquitto` Docker image](https://github.com/eclipse/mosquitto/tree/master/docker/2.0),
which runs with a `uid` and `gid` of `1883`. This component can run under a `restricted`
[pod security standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/).

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - https://github.com/marinatedconcrete/config/kustomization/components/mosquitto
```

See below for additionally required patches and secrets.

## Required Secrets

### `mosquitto-password-conf-secret`

This contains the logins that you want to be included in the `password.conf` file in the container.
Each key will be treated as the username, and the contents the password to hash and add to
`password.conf`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mosquitto-password-conf-secret
stringData:
  someuser: super-secure-unhashed-password
```

## Optional Patches

### Add Configuration Options

If you want to change the [configuration](https://mosquitto.org/man/mosquitto-conf-5.html) of
`mosquitto`, you can patch in your own config files. You can place as many `.conf` files as you
would like in the `ConfigMap`.

#### `kustomization.yml`

```yaml
configMapGenerator:
  - files:
      - configmap/logging.conf
    name: mosquitto-config-configmap
patches:
  - path: patches/add_custom_config.yml
    target:
      kind: Deployment
      name: mosquitto-deployment
```

#### `configmap/logging.conf`

```
log_type all
```

#### `patches/add_custom_config.yml`

This patch is taking advantage of the `$patch: delete` functionality of Kustomize to remove the
`emptyDir` configuration and instead mount the `ConfigMap` that was just defined.

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: this-is-ignored-but-is-required
spec:
  template:
    spec:
      volumes:
        - emptyDir:
            $patch: delete
          name: mosquitto-config
          configMap:
            name: mosquitto-config-configmap
```
