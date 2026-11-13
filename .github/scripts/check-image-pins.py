#!/usr/bin/env python3
"""Fail when an `images:` entry matches no image in a rendered overlay.

Kustomize ignores an entry that matches nothing, so the image floats.
"""

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

OVERLAYS: Path = Path("kustomization/overlays")


def kustomization(directory: Path) -> dict[str, Any]:
    data: dict[str, Any] = yaml.safe_load((directory / "kustomization.yml").read_text())
    return data


def closure(directory: Path) -> set[Path]:
    """Return the directory and every directory that it pulls in."""
    found = {directory}
    for key in ("bases", "components", "resources"):
        for item in kustomization(directory).get(key, []):
            child = Path(os.path.normpath(directory / item))
            if child.is_dir():
                found |= closure(child)
    return found


def applied(entry: dict[str, str]) -> str:
    """Return the image that kustomize writes when the entry applies."""
    # A tag in the name matches only that tag.  Kustomize replaces it.
    name = re.sub(r":[^/:]*$", "", entry.get("newName", entry["name"]))
    return f"{name}:{entry['newTag']}"


def render(overlay: Path) -> set[str]:
    result = subprocess.run(
        ["kustomize", "build", "--enable-helm", str(overlay)],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"kustomize build failed for {overlay}:\n{result.stderr}")
    return set(re.split(r"[\s\"']+", result.stdout))


def main() -> int:
    pins: set[tuple[Path, str]] = set()
    live: set[tuple[Path, str]] = set()
    for overlay in sorted(OVERLAYS.glob("*/*")):
        rendered = render(overlay)
        for directory in closure(overlay):
            for entry in kustomization(directory).get("images", []):
                pins.add((directory, entry["name"]))
                if applied(entry) in rendered:
                    live.add((directory, entry["name"]))
    dead = pins - live
    for directory, name in sorted(dead):
        print(f"{directory}: `{name}` matches no image", file=sys.stderr)
    if not dead:
        print(f"All {len(pins)} image pins match an image.")
    return 1 if dead else 0


if __name__ == "__main__":
    sys.exit(main())
