k8s-scale
=========

This role scales every `Deployment`, `StatefulSet`, and CNPG `Cluster` in one
namespace.  Down scales each workload to zero replicas and hibernates each CNPG
`Cluster`.  Up restores each workload to its previous replica count and resumes each
CNPG `Cluster`.  The role finds these workloads live in the cluster.  It does not use a
hardcoded list.

The role also sets the namespace's Argo CD `Application` to manual or automated sync.
Every generated `Application` sets `syncPolicy.automated: {}`.  This setting turns off
`selfHeal`.  Argo CD then syncs only on a git revision change.  It does not sync on
live-state drift.  Manual sync stops Argo CD from fighting a scaled-down namespace.

Requirements
------------

The role needs the `kubernetes.core` collection.  It needs a working kubeconfig context
for the target cluster.  The role talks only to the Kubernetes API.

The role does not call the `argocd` CLI.  `tasks/argocd_sync_policy.yml` patches the
`Application` object's `spec.syncPolicy` field directly.  This is the same field `argocd
app set --sync-policy` patches.  This design needs no `argocd` CLI login and no `--core`
mode.  It also does not depend on the current kube context's namespace.  Every Kubernetes
API call in the role uses `k8s_scale_context` explicitly.

Role Variables
--------------

See `defaults/main.yml`.  The two variables every caller must set are:

- `k8s_scale_direction`: `down`, `up`, or `restore-sync`.  `restore-sync` re-arms
  auto-sync only.  It does not change replica counts.  See "Emergency-shutdown
  caveats" below.
- `k8s_scale_namespace`: the namespace to operate on.  The role also uses this value,
  unchanged, as the name of the Argo CD `Application` object it patches.  This works
  because `plays/codegen/templates/resources/application.yml.j2` names every
  `Application` after its overlay directory.  For every namespace this role currently
  handles, the directory name and the namespace name match.  This is **not** a general
  rule.  For example, the `external-services` overlay sets `namespace: external-svc`.

`k8s_scale_exclude` (default `[]`) lists workload names to skip in one namespace.  The
role does not scale these workloads down or up.

Within a namespace
------------------

The role finds every workload in one pass.  It then handles the workloads in two
groups: `Deployment`s and `StatefulSet`s in one group, CNPG `Cluster`s in the other.
For each group, the role patches every object with `wait: false`.  No patch waits for
the previous patch.  The role then waits for every object in that group at once, in a
separate retrying task per object.  The cluster does the real work on its own, apart
from Ansible's poll order.  This wait is a real parallel wait, not a sequential one.  By
the time the role polls the last object, that object has had the same wall-clock time to
finish as the first object.

The two groups stay in order relative to each other.  On the way down, the
`Deployment`s and `StatefulSet`s go to zero first.  The CNPG `Cluster`s hibernate after
that.  On the way up, the order reverses.  An application's CNPG `Cluster` must reach
`Ready` before the role restores that application's own replica count.

**The wait on the way down checks for `Pod`s, not workload status.**  A `Deployment` or
`StatefulSet` can report 0 replicas in its own status as soon as its `Pod`s start to
terminate.  This happens before the `Pod`s are actually gone.  A `Pod` in its termination
grace period is often excluded from that count before its Longhorn volume actually
releases.  Longhorn maintenance that starts on the status signal can then hit a volume
that is still attached.  The down-side wait queries the workload's own `Pod`s directly, by
its pod selector.  It waits until that list of `Pod`s is empty.

Between namespaces
-------------------

This role scales exactly one namespace per call.  It does not choose the order between
namespaces.  The caller sets the order.  `group_vars/all.yml` stores the order for this
repository's cluster, in `k8s_scale_down_order` and `k8s_scale_up_order`, along with the
rationale for that order.

`plays/k8s/scale-order-check.yml` checks that both lists name the same set of
namespaces, with no duplicates.  CI runs this check as `just ansible-scale-order-check`.
This check does not confirm that every namespace *needing* scale coverage is on a list.
A new Longhorn-backed overlay left off both lists is a silent gap.  This check does not
detect that gap.

Emergency-shutdown caveats
---------------------------

- On the **down** path, disabling auto-sync uses `ignore_errors: true`
  (`k8s_scale_argocd_best_effort: true`).  This step is an optimization only.  It stops
  Argo CD from contending with the scale-to-zero step below.  `selfHeal: false` already
  stops Argo CD from fighting the role, so this step is not a correctness requirement.  A
  fatal error here would be a regression.  A single failed patch at namespace 1 of an
  emergency shutdown could abort the whole run.  The cluster may be on battery power
  during this kind of shutdown.  The run must not scale down *nothing* because of one
  failed patch.
- On the **up** path, the same call is strict.  A namespace left on manual sync forever
  is a silent failure.
- The scale-to-zero/hibernate and scale-up/resume steps are strict in both directions.  A
  workload that fails to reach its target state stops the run.  The role does not skip
  this failure silently.
- "Strict" means the *namespace* fails loudly.  It does not mean the whole run stops at
  that namespace.  `plays/k8s/scale-down.yml`, `scale-up.yml`, and `restore-sync.yml`
  each include `plays/k8s/tasks/scale-one-namespace.yml`.  That file wraps the
  per-namespace call in a `rescue:` block.  This block records the failure and moves to
  the next namespace.  Each play fails once at the end, with the full list of failed
  namespaces.  A stuck workload in namespace 3 of 24 does not stop the other 21
  namespaces.
- Use `plays/k8s/restore-sync.yml` (`k8s_scale_direction: restore-sync`) to re-arm
  auto-sync across every namespace, without changing replica counts.  Run this play if a
  scale-up run, or anything else, leaves some namespaces on manual sync.

Dependencies
------------

None.  This role does not depend on any other Ansible role.  See "Requirements" above
for the required collection.

Example Playbook
-----------------

    - hosts: localhost
      gather_facts: false
      tasks:
        - name: Scale down namespace
          ansible.builtin.include_role:
            name: k8s-scale
          vars:
            k8s_scale_direction: down
            k8s_scale_namespace: "{{ item }}"
            k8s_scale_exclude: "{{ k8s_scale_excludes[item] | default([]) }}"
          loop: "{{ k8s_scale_down_order }}"

License
-------

BSD

Author Information
------------------

sdwilsh
