#!/usr/bin/env bash
# Called only by the root-owned systemd log collector service.
set -Eeuo pipefail
[[ ${1:-} =~ ^[1-9][0-9]*$ ]] || exit 2
name="agent-sandbox-${1}-proxy"
while :; do
  if podman --cgroup-manager=cgroupfs container exists "$name"; then
    # Tail a small startup window; a restart can duplicate some log lines.
    podman --cgroup-manager=cgroupfs logs --follow --tail=30 "$name" 2>&1 || :
  fi
  sleep 3
done
