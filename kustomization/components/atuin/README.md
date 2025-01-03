# Atuin Component

This will deploy [Atuin](https://docs.atuin.sh/), and assumes you are using [Traefik Proxy](https://traefik.io/traefik).

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/atuin
```

This components requires a postgresql database.  How that is created is left to the user.

See below for additionally required patches.

## Required Patches

### Add configuration environment variables

The database host, password secret file, and username must be provided to the init container to generate a config file.

#### `kustomization.yml`

```yaml
```

#### `patches/set_config_env.yml`

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: this-is-ignored-but-is-required
spec:
  template:
    spec:
      initContainers:
        - env:
            - name: ATUIN_DB_HOST
              value: some.connection.to.postgres
            - name: ATUIN_DB_PASSWORD_SECRET_FILE
              value: /postgresql-secrets/password
            - name: ATUIN_DB_USERNAME
              value: atuin
          name: generate-config
          volumeMounts:
            - mountPath: /postgresql-secrets
              name: postgresql-secrets
              readOnly: true
      volumes:
        - name: postgresql-secrets
          secret:
            secretName: some-postgresql-secret
```
