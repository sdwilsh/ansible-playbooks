#!/usr/bin/env bash
set -euo pipefail

# Read the existing mack-kairos tag names on standard input.  Print the next
# CalVer version for the month prefix in $1, for example 2026.11.

prefix="${1:?usage: next-mack-kairos-version.sh <YYYY.M>}"

max=-1
while IFS= read -r tag || [[ -n "$tag" ]]; do
    if [[ "$tag" =~ ^mack-kairos-${prefix//./\\.}\.([0-9]+)$ ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        if ((n > max)); then
            max=$n
        fi
    fi
done

printf '%s.%d\n' "$prefix" $((max + 1))
