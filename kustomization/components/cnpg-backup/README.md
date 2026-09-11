# CloudNativePG Backup Component

This component gives your `Namespace` the parts that a CloudNativePG database needs to write a
backup to [Garage](https://garagehq.deuxfleurs.fr/).  It gives an `ObjectStore`, the rights that
the check `Pod` needs, and a path from the database to Garage.

It also makes Argo CD wait.  Your overlay gives a `Backup` and a check `Pod` as `PreSync` hooks.
The check `Pod` reads the `Backup` through the API server, and it stops the sync until the backup
is complete.  A sync that changes the database therefore starts from a good backup.

# Example Usage

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/cnpg-backup
  - ../../../components/networkpolicy-allow-to-api-server
```

## Your Namespace Must Also Have The API Server Component

Add the `networkpolicy-allow-to-api-server` component to the same overlay.  This component gives
the `hogs.tswn.us/api-server-client` label to the `Pod`s of the database, through
`spec.inheritedMetadata` on the `Cluster`, and to the check `Pod`.  It does not give the path.
Your overlay gives the path, so that the list of components shows each type of access that your
`Namespace` has.

An overlay that forgets the component stops at the next sync.  The check `Pod` calls the API
server, the hook fails, and Argo CD stops the sync.

## What Your Overlay Must Give

- a `Cluster`, and a `ScheduledBackup` for the backup of each day.
- a `Backup` with the `PreSync` hook annotations, and a check `Pod` that names it in the
  `BACKUP_RESOURCE` variable.  The check `Pod` needs the
  `app.kubernetes.io/component: wait-for-backup` label, because this component finds it that way.
- a patch on the `ObjectStore` that sets `destinationPath` to the bucket path of your
  `Namespace`.  The value of this component is a placeholder.

`kustomization/overlays/prod/atuin/` shows each of these.
