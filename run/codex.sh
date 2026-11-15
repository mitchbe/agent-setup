#!/usr/bin/env bash
# Restricted network: only the allowlisted API endpoints through proxy sidecar.
set -Eeuo pipefail
TOOL=codex
NETWORK_MODE=restricted
source "$(dirname -- "${BASH_SOURCE[0]}")/_common.sh" "$@"
