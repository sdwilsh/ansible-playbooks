#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: next-calver-version.sh <image> <YYYY.M>}"
prefix="${2:?usage: next-calver-version.sh <image> <YYYY.M>}"

max=-1
while IFS= read -r tag || [[ -n "$tag" ]]; do
    if [[ "$tag" =~ ^${image}-${prefix//./\\.}\.([0-9]+)$ ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        if ((n > max)); then
            max=$n
        fi
    fi
done

printf '%s.%d\n' "$prefix" $((max + 1))
