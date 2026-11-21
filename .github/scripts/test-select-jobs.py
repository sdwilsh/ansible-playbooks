#!/usr/bin/env python3
"""Test `select-jobs.py`.  Each case lists changed files and the jobs they select."""

import importlib.machinery
import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
LOADER = importlib.machinery.SourceFileLoader("select_jobs", str(HERE / "select-jobs.py"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
select_jobs = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(select_jobs)

IMAGES = {"mack", "nut-shutdown-agent", "sif", "wireguard-egress"}
CONTAINER = {"ansible", "go", "kustomize-build", "renovate-validate", "shell-docker-lint"}

# name: (changed files, jobs that run)
CASES: dict[str, tuple[list[str], set[str]]] = {
    "docs only": (["README.md", ".vscode/settings.json"], set()),
    "unlisted path": (["newdir/thing.txt"], IMAGES | CONTAINER | {"devcontainer"}),
    "unlisted path with docs": (["README.md", "scratch.sql"], IMAGES | CONTAINER | {"devcontainer"}),
    "empty change": ([], set()),
    "mack Containerfile only": (
        ["images/mack/Containerfile"],
        {"devcontainer", "mack", "shell-docker-lint"},
    ),
    "mack build script": (
        ["images/mack/build_files/packages.sh"],
        {"devcontainer", "mack", "shell-docker-lint"},
    ),
    "sif test script": (
        ["images/sif/test/stub-gufo.sh"],
        {"devcontainer", "shell-docker-lint", "sif"},
    ),
    "sif test in python": (["images/sif/test/e2e.py"], {"sif"}),
    "kustomization only": (
        ["kustomization/overlays/prod/dns/kustomization.yml"],
        {"devcontainer", "kustomize-build"},
    ),
    "kustomization script": (
        ["kustomization/components/atuin/configmap/generate-server-toml.sh"],
        {"devcontainer", "kustomize-build", "shell-docker-lint"},
    ),
    "ansible plays": (["plays/k8s/scale-down.yml"], {"ansible", "devcontainer"}),
    "ansible role": (["roles/docker/tasks/main.yml"], {"ansible", "devcontainer"}),
    "ansible inventory variables": (["group_vars/all.yml"], {"ansible", "devcontainer"}),
    "mack ansible file": (
        ["images/mack/build_files/ansible/tasks.yml"],
        {"ansible", "devcontainer", "mack"},
    ),
    "justfile": (["justfile"], CONTAINER | {"devcontainer"}),
    "devcontainer Containerfile": (
        [".devcontainer/Containerfile"],
        CONTAINER | {"devcontainer"},
    ),
    "python requirements": (["requirements.txt"], CONTAINER | {"devcontainer"}),
    "go source": (
        ["kustomization/overlays/prod/traefik/plugins/cloudflarerealip/cloudflarerealip.go"],
        {"devcontainer", "go", "kustomize-build"},
    ),
    "renovate config": (["renovate.json"], {"devcontainer", "renovate-validate"}),
    "image pin check": (
        [".github/scripts/check-image-pins.py"],
        {"devcontainer", "kustomize-build"},
    ),
    "calver script": (
        [".github/scripts/next-calver-version.sh"],
        {"devcontainer", "mack", "shell-docker-lint"},
    ),
    "release workflow": ([".github/workflows/release-image.yml"], {"mack"}),
    "image workflow": ([".github/workflows/build-sif.yml"], {"sif"}),
    "CI workflow": ([".github/workflows/devcontainer-ci.yml"], CONTAINER | IMAGES | {"devcontainer"}),
    "selection script": (
        [".github/scripts/select-jobs.py"],
        CONTAINER | IMAGES | {"devcontainer"},
    ),
    "unrelated workflow": ([".github/workflows/cloudflare-ip-update.yml"], set()),
    "two groups": (
        ["plays/k8s/scale-down.yml", "images/sif/Containerfile"],
        {"ansible", "devcontainer", "shell-docker-lint", "sif"},
    ),
}


class SelectJobs(unittest.TestCase):
    def test_cases(self) -> None:
        for name, (files, expected) in CASES.items():
            with self.subTest(name):
                chosen = select_jobs.select(files)
                self.assertEqual({job for job, on in chosen.items() if on}, expected)

    def test_everything(self) -> None:
        chosen = select_jobs.select([], everything=True)
        self.assertTrue(all(chosen.values()))
        self.assertEqual(set(chosen), set(select_jobs.JOBS))

    def test_glob_boundaries(self) -> None:
        match = select_jobs.glob_to_regex
        self.assertTrue(match("**/*.go").match("a.go"))
        self.assertTrue(match("**/*.go").match("a/b/c.go"))
        self.assertTrue(match("images/mack/**").match("images/mack/a/b"))
        self.assertFalse(match("images/mack/**").match("images/mack"))
        self.assertFalse(match("*.yml").match("a/b.yml"))
        self.assertFalse(match("*.yml").match("b.yaml"))

    def test_workflow_uses_every_job(self) -> None:
        workflow = (HERE.parent / "workflows" / "devcontainer-ci.yml").read_text()
        for job in select_jobs.JOBS:
            with self.subTest(job):
                self.assertTrue(f"needs.changes.outputs.{job}" in workflow, f"{job} has no needs.changes.outputs reference")


if __name__ == "__main__":
    unittest.main()
