#!/usr/bin/env python3
"""Pick the CI jobs that a set of changed files needs.

Read changed paths from stdin, one per line.  Or use `--base REV` to read
them from git, or `--all` to select every job.  Print one `<job>=true` or
`<job>=false` line for each job.  The lines suit `$GITHUB_OUTPUT`.

A path that matches no entry and is not in IGNORED selects every job.  A
wasted run costs less than a skipped check.
"""

import argparse
import re
import subprocess
import sys
from collections.abc import Iterable

# A change to one of these paths selects every job.  They are the CI
# workflow and the files that decide what runs.
EVERYTHING: tuple[str, ...] = (
    ".github/scripts/select-jobs.py",
    ".github/scripts/test-select-jobs.py",
    ".github/workflows/devcontainer-ci.yml",
)

# No job reads these paths.  A change to them alone selects no job.  The two
# workflows run on their own triggers.
IGNORED: tuple[str, ...] = (
    "**/*.md",
    ".github/workflows/cloudflare-ip-update.yml",
    ".github/workflows/kairos-upgrade-order.yml",
    ".vscode/**",
)

# A job that runs in the devcontainer image reads all of these.
DEVCONTAINER: tuple[str, ...] = (
    ".devcontainer/**",
    ".github/actions/devcontainer/**",
    ".github/scripts/devcontainer-run.sh",
    "justfile",
    "package.json",
    "pnpm-lock.yaml",
    "requirements.txt",
    "requirements.yml",
)

# The key is the job name in `devcontainer-ci.yml`.  The value lists the
# paths that the job reads, besides EVERYTHING and, for a job that runs in
# the devcontainer image, DEVCONTAINER.
TABLE: dict[str, tuple[str, ...]] = {
    # `ansible-lint` reads every YAML file outside `.github/` and
    # `kustomization/`.  The recipes read the inventory and the variables.
    "ansible": (
        "*.yaml",
        "*.yml",
        ".ansible-lint",
        "ansible-ci.cfg",
        "ansible.cfg",
        "butane/**",
        "group_vars/**",
        "host_vars/**",
        "images/**/*.yaml",
        "images/**/*.yml",
        "plays/**",
        "prod-inventory",
        "requirements.yml",
        "roles/**",
        "site.yml",
    ),
    # Each recipe walks every Go module and every `.go` file.
    "go": (
        "**/*.go",
        "**/go.mod",
        "**/go.sum",
        "kustomization/overlays/prod/traefik/plugins/**",
    ),
    # This job also runs the recipes that read only `kustomization/`.  These
    # are `coredns-drift-check`, `tdarr-flows-test` and `traefik-pin-check`.
    # The last one also reads the devcontainer Containerfile.
    # `egress-proxy-codegen-check` also reads its play and templates.
    "kustomize-build": (
        ".github/scripts/check-image-pins.py",
        ".github/scripts/check-named-ports.py",
        "kustomization/**",
        "plays/codegen/egress-proxy.yml",
        "plays/codegen/templates/resources/egress-proxy-*",
        "plays/codegen/templates/resources/kustomization.yml.j2",
    ),
    "mack": (
        ".github/scripts/next-calver-version.sh",
        ".github/workflows/build-mack.yml",
        ".github/workflows/release-image.yml",
        "images/mack/**",
    ),
    "nut-shutdown-agent": (
        ".github/workflows/build-nut-shutdown-agent.yml",
        "images/nut-shutdown-agent/**",
    ),
    "renovate-validate": ("renovate.json",),
    "shell-docker-lint": (
        "**/*.sh",
        "**/*Containerfile*",
        "**/justfile",
        ".github/scripts/next-calver-version.sh",
        ".github/scripts/test-next-calver-version.sh",
        ".hadolint.yaml",
    ),
    # The sif test starts each production model list.
    "sif": (
        ".github/workflows/build-sif.yml",
        "images/sif/**",
        "kustomization/overlays/prod/local-llm/*/configmap/models.txt",
    ),
    "wireguard-egress": (
        ".github/workflows/build-wireguard-egress.yml",
        "images/wireguard-egress/**",
    ),
}

# These jobs run in the devcontainer image.
IN_DEVCONTAINER: frozenset[str] = frozenset(
    {"ansible", "go", "kustomize-build", "renovate-validate", "shell-docker-lint"}
)

# The `devcontainer` job builds the image.  It runs when a job needs the image.
IMAGE_JOB = "devcontainer"

JOBS: tuple[str, ...] = tuple(sorted({*TABLE, IMAGE_JOB}))


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a glob.  `**` crosses a slash.  `*` and `?` do not."""
    out: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def patterns(job: str) -> list[re.Pattern[str]]:
    globs = [*EVERYTHING, *TABLE[job]]
    if job in IN_DEVCONTAINER:
        globs += DEVCONTAINER
    return [glob_to_regex(glob) for glob in globs]


def select(files: Iterable[str], everything: bool = False) -> dict[str, bool]:
    """Return a map from each job name to whether the files select it."""
    files = [f for f in files if f]
    ignored = [glob_to_regex(glob) for glob in IGNORED]
    matchers = {job: patterns(job) for job in TABLE}
    unlisted = any(
        not any(p.match(f) for p in ignored)
        and not any(p.match(f) for ps in matchers.values() for p in ps)
        for f in files
    )
    selected = {
        job: everything or unlisted or any(p.match(f) for p in matchers[job] for f in files)
        for job in TABLE
    }
    selected[IMAGE_JOB] = any(selected[job] for job in IN_DEVCONTAINER)
    return dict(sorted(selected.items()))


def changed_files(base: str) -> list[str]:
    """List the paths that differ from the merge base of `base` and HEAD."""
    result = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", f"{base}...HEAD"],
        capture_output=True,
        check=True,
        text=True,
    )
    return result.stdout.splitlines()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--all", action="store_true", help="select every job")
    source.add_argument("--base", help="read changed paths from git, against this revision")
    args = parser.parse_args()

    if args.all:
        files: list[str] = []
    elif args.base:
        files = changed_files(args.base)
    else:
        files = sys.stdin.read().splitlines()

    for job, chosen in select(files, everything=args.all).items():
        print(f"{job}={str(chosen).lower()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
