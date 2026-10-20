#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
log_file=$(mktemp)
trap 'rm -f "$log_file"' EXIT
export ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_NOCOLOR=1

ansible-playbook "$test_dir/converge.yml" "$@"
ansible-playbook "$test_dir/converge.yml" "$@" | tee "$log_file"

# Вторая попытка должна оставить все хосты без изменений.
if ! awk '
    /^PLAY RECAP / { recap = 1; next }
    recap && /changed=/ {
        hosts++
        if ($0 !~ /changed=0([[:space:]]|$)/) changed = 1
    }
    END { exit (!hosts || changed) }
' "$log_file"; then
    echo "FAIL: the second run changed the host, or no hosts were tested." >&2
    exit 1
fi

echo "PASS: deployment checks and idempotence."
