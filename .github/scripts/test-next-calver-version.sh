#!/usr/bin/env bash
set -euo pipefail

script="$(dirname "$0")/next-calver-version.sh"
failed=0

check() {
    local want=$1 image=$2 prefix=$3 tags=$4 got
    got=$(printf '%b' "$tags" | "$script" "$image" "$prefix")
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: want ${want}, got ${got} (${image} ${prefix}, input: ${tags})"
        failed=1
    fi
}

check 2026.11.0 mack 2026.11 ''
check 2026.11.5 mack 2026.11 'mack-2026.11.4\nmack-2026.11.1\n'
check 2026.11.11 mack 2026.11 'mack-2026.11.4\nmack-2026.11.10\n'
check 2026.1.0 mack 2026.1 'mack-2026.11.3\nmack-2026.111.3\n'
check 2026.11.3 mack 2026.11 'mack-2026.11.2'
check 2026.11.0 mack 2026.11 'mack-kairos-2026.11.7\n'
check 2026.11.8 mack-kairos 2026.11 'mack-kairos-2026.11.7\nmack-2026.11.40\n'
check 2026.11.0 kairos 2026.11 'mack-kairos-2026.11.5\n'
check 2026.11.0 mack 2026.11 'mack-2026.11.4-rc1\n'

if ((failed)); then
    exit 1
fi
echo "OK"
