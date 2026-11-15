#!/usr/bin/env bash
# Unrestricted network: direct outbound networking (host audit, if enabled).
set -Eeuo pipefail
TOOL=codex
NETWORK_MODE=networked
source "$(dirname -- "${BASH_SOURCE[0]}")/_common.sh" "$@"
