#!/usr/bin/env python3
"""Fail when a NetworkPolicy port name maps to more than one number.

kube-router v2.11 gives each number of a port name its own ipset, named
by a list index in Go map order.  The order can change at a full sync.  So
when one name maps to two numbers in one rule, new connections fail for
about one second during such a sync.

An ingress rule maps the name on the pods that the policy selects.  An
egress rule maps it on the pods that its `to` peers select.  The check sees
the pods that the rendered overlays define, and the operator pods that
`POD_SOURCES` describes.  It does not see other operator pods, or pods that
are applied by hand.  The drop-pods are applied by hand, so they must keep
`web` on 9101.
"""

import os
import subprocess
import sys
from collections import defaultdict
from collections.abc import Callable, Iterable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

OVERLAYS: Path = Path("kustomization/overlays")

Labels = Mapping[str, str]
Object = dict[str, Any]
# A container port, keyed by name and protocol, as kube-router matches it.
PortKey = tuple[str, str]
Shape = tuple[Labels, dict[PortKey, int]]
ShapeReader = Callable[[Object], Iterator[Shape]]


@dataclass(frozen=True)
class Pod:
    namespace: str
    labels: Labels
    ports: Mapping[PortKey, int]
    source: str


@dataclass(frozen=True)
class Finding:
    rule: str
    port: PortKey
    numbers: Mapping[int, list[str]]


class Loader(yaml.SafeLoader):
    pass


# Some CRD schemas hold a bare `=` in an enum.  YAML 1.1 reads it as the
# "value" tag, and `SafeLoader` has no constructor for that tag.
def construct_value(loader: Loader, node: yaml.ScalarNode) -> str:
    return str(loader.construct_scalar(node))


Loader.add_constructor("tag:yaml.org,2002:value", construct_value)


def render(overlay: Path) -> list[Object]:
    result = subprocess.run(
        ["kustomize", "build", "--enable-helm", str(overlay)],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"kustomize build failed for {overlay}:\n{result.stderr}")
    return [document for document in yaml.load_all(result.stdout, Loader=Loader) if document]


def dig(obj: Object, *keys: str) -> Any:
    """Follow the keys.  A key that is absent or null gives an empty map."""
    for key in keys:
        obj = obj.get(key) or {}
    return obj


def group_kind(obj: Object) -> str:
    group = obj["apiVersion"].rpartition("/")[0]
    return f"{group}/{obj['kind']}" if group else obj["kind"]


def ports_of(spec: Object) -> dict[PortKey, int]:
    return {
        (port["name"], port.get("protocol", "TCP")): port["containerPort"]
        for container in spec.get("containers") or []
        for port in container.get("ports") or []
        if "name" in port
    }


def template_at(*path: str) -> ShapeReader:
    def shapes(obj: Object) -> Iterator[Shape]:
        template = dig(obj, *path)
        if template:
            yield dig(template, "metadata", "labels"), ports_of(dig(template, "spec"))

    return shapes


def operator_pods(
    pod_labels: Callable[[Object], Labels],
    ports: Mapping[PortKey, int],
    variants: Iterable[Labels] = ({},),
) -> ShapeReader:
    """Describe the pods that an operator makes from one custom resource."""

    def shapes(obj: Object) -> Iterator[Shape]:
        for variant in variants:
            yield {**pod_labels(obj), **variant}, dict(ports)

    return shapes


def prometheus_labels(obj: Object) -> Labels:
    name = obj["metadata"]["name"]
    return {
        **dig(obj, "spec", "podMetadata", "labels"),
        "app.kubernetes.io/instance": name,
        "app.kubernetes.io/managed-by": "prometheus-operator",
        "app.kubernetes.io/name": "prometheus",
        "operator.prometheus.io/name": name,
        "prometheus": name,
    }


def alertmanager_labels(obj: Object) -> Labels:
    name = obj["metadata"]["name"]
    return {
        **dig(obj, "spec", "podMetadata", "labels"),
        "alertmanager": name,
        "app.kubernetes.io/instance": name,
        "app.kubernetes.io/managed-by": "prometheus-operator",
        "app.kubernetes.io/name": "alertmanager",
    }


def cnpg_labels(obj: Object) -> Labels:
    name = obj["metadata"]["name"]
    return {
        **dig(obj, "spec", "inheritedMetadata", "labels"),
        "app.kubernetes.io/component": "database",
        "app.kubernetes.io/instance": name,
        "app.kubernetes.io/managed-by": "cloudnative-pg",
        "app.kubernetes.io/name": "postgresql",
        "cnpg.io/cluster": name,
        "cnpg.io/podRole": "instance",
    }


# The kinds whose pods this check can see, and how to read each one.  The
# operator ports and labels copy what the operators give their pods.
POD_SOURCES: Mapping[str, ShapeReader] = {
    "Pod": template_at(),
    "apps/DaemonSet": template_at("spec", "template"),
    "apps/Deployment": template_at("spec", "template"),
    "apps/ReplicaSet": template_at("spec", "template"),
    "apps/StatefulSet": template_at("spec", "template"),
    # A Rollout with `workloadRef` has no template.  Its Deployment holds it.
    "argoproj.io/Rollout": template_at("spec", "template"),
    "batch/CronJob": template_at("spec", "jobTemplate", "spec", "template"),
    "batch/Job": template_at("spec", "template"),
    "monitoring.coreos.com/Alertmanager": operator_pods(
        alertmanager_labels,
        {("web", "TCP"): 9093, ("mesh-tcp", "TCP"): 9094, ("mesh-udp", "UDP"): 9094, ("reloader-web", "TCP"): 8080},
    ),
    "monitoring.coreos.com/Prometheus": operator_pods(
        prometheus_labels,
        {("web", "TCP"): 9090, ("reloader-web", "TCP"): 8080},
    ),
    "postgresql.cnpg.io/Cluster": operator_pods(
        cnpg_labels,
        {("postgresql", "TCP"): 5432, ("metrics", "TCP"): 9187, ("status", "TCP"): 8000},
        variants=(
            {"cnpg.io/instanceRole": "primary", "role": "primary"},
            {"cnpg.io/instanceRole": "replica", "role": "replica"},
        ),
    ),
}


def matches(selector: Object | None, labels: Labels) -> bool:
    if selector is None:
        return True
    for key, value in dig(selector, "matchLabels").items():
        if labels.get(key) != value:
            return False
    for expression in selector.get("matchExpressions") or []:
        key, operator, values = expression["key"], expression["operator"], expression.get("values") or []
        match operator:
            case "In":
                ok = labels.get(key) in values
            case "NotIn":
                ok = labels.get(key) not in values
            case "Exists":
                ok = key in labels
            case "DoesNotExist":
                ok = key not in labels
            case _:
                sys.exit(f"unknown selector operator {operator!r}")
        if not ok:
            return False
    return True


@dataclass(frozen=True)
class Cluster:
    namespaces: Mapping[str, Labels]
    pods: list[Pod]
    policies: list[Object]

    def pods_in(self, namespace: str, selector: Object | None) -> list[Pod]:
        return [pod for pod in self.pods if pod.namespace == namespace and matches(selector, pod.labels)]

    def namespace_labels(self, namespace: str) -> Labels:
        return {**self.namespaces.get(namespace, {}), "kubernetes.io/metadata.name": namespace}

    def peer_pods(self, policy_namespace: str, peer: Object) -> list[Pod]:
        if "namespaceSelector" in peer:
            names = {pod.namespace for pod in self.pods} | set(self.namespaces)
            return [
                pod
                for name in sorted(names)
                if matches(peer["namespaceSelector"], self.namespace_labels(name))
                for pod in self.pods_in(name, peer.get("podSelector"))
            ]
        if "podSelector" in peer:
            return self.pods_in(policy_namespace, peer["podSelector"])
        return []


def build_cluster(rendered: Mapping[Path, list[Object]]) -> Cluster:
    # ArgoCD puts an object with no namespace in its Application's namespace.
    destination = {
        Path(obj["spec"]["source"]["path"]): obj["spec"]["destination"]["namespace"]
        for objects in rendered.values()
        for obj in objects
        if obj["kind"] == "Application" and "path" in dig(obj, "spec", "source")
    }
    namespaces: dict[str, Labels] = {}
    pods: list[Pod] = []
    policies: list[Object] = []
    for overlay, objects in rendered.items():
        for obj in objects:
            kind = group_kind(obj)
            if kind == "Namespace":
                namespaces[obj["metadata"]["name"]] = dig(obj, "metadata", "labels")
                continue
            if kind != "networking.k8s.io/NetworkPolicy" and kind not in POD_SOURCES:
                continue
            namespace = obj["metadata"].get("namespace") or destination.get(overlay)
            if namespace is None:
                sys.exit(f"{overlay}: {kind} {obj['metadata']['name']} has no namespace and no Application")
            if kind == "networking.k8s.io/NetworkPolicy":
                policies.append({**obj, "metadata": {**obj["metadata"], "namespace": namespace}})
                continue
            source = f"{namespace}/{obj['metadata']['name']} ({obj['kind']})"
            for labels, ports in POD_SOURCES[kind](obj):
                pods.append(Pod(namespace, labels, ports, source))
    return Cluster(namespaces, pods, policies)


def numbers(pods: Iterable[Pod], port: PortKey) -> dict[int, list[str]]:
    found: dict[int, set[str]] = defaultdict(set)
    for pod in pods:
        if port in pod.ports:
            found[pod.ports[port]].add(pod.source)
    return {number: sorted(sources) for number, sources in sorted(found.items())}


def findings(cluster: Cluster) -> Iterator[Finding]:
    for policy in cluster.policies:
        namespace = policy["metadata"]["namespace"]
        spec = policy["spec"]
        rule_name = f"{namespace}/{policy['metadata']['name']}"
        targets = cluster.pods_in(namespace, spec.get("podSelector"))
        for direction, peer_key in (("ingress", "from"), ("egress", "to")):
            for index, rule in enumerate(spec.get(direction) or []):
                if direction == "ingress":
                    candidates = targets
                elif rule.get(peer_key):
                    candidates = [pod for peer in rule[peer_key] for pod in cluster.peer_pods(namespace, peer)]
                else:
                    # An egress rule to every peer has no ipset to order.
                    continue
                for entry in rule.get("ports") or []:
                    if not isinstance(entry.get("port"), str):
                        continue
                    port = (entry["port"], entry.get("protocol", "TCP"))
                    found = numbers(candidates, port)
                    if len(found) > 1:
                        yield Finding(f"{rule_name} {direction}[{index}]", port, found)


def main() -> int:
    rendered = {Path(os.path.normpath(overlay)): render(overlay) for overlay in sorted(OVERLAYS.glob("*/*"))}
    cluster = build_cluster(rendered)
    problems = list(findings(cluster))
    for finding in problems:
        name, protocol = finding.port
        print(f"{finding.rule}: port `{name}`/{protocol} maps to {len(finding.numbers)} numbers:", file=sys.stderr)
        for number, sources in finding.numbers.items():
            print(f"  {number}: {', '.join(sources)}", file=sys.stderr)
    if problems:
        print(
            "Give each of these pods the same number for the port name, or put the numbers in the rule.",
            file=sys.stderr,
        )
        return 1
    print(
        f"Each named port in {len(cluster.policies)} NetworkPolicies maps to one number"
        f" on {len(cluster.pods)} pod templates."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
