#!/usr/bin/env bash
# Deliberately remove only one logical sandbox; shared agents account is never removed here.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root
[[ $# == 1 ]] || fail 'Usage: remove-agent-sandbox.sh NUMBER'
validate_number "$1"
require_account
CURRENT_STAGE=initialization
trap 'printf "ERROR: remove-agent-sandbox.sh stopped during %s (line %s, exit %s).\n" "$CURRENT_STAGE" "$LINENO" "$?" >&2' ERR
printf 'REMOVE AGENT SANDBOX %s\n  No removal affects other sandboxes or the shared agents account.\n' "$SANDBOX_NUM"

CURRENT_STAGE='stop container processes'
info '[1] Stop sandbox Podman workloads'
printf '  Stop/remove rootless Podman pod: agent-sandbox-%s\n' "$SANDBOX_NUM"
printf '  Stop/remove proxy container: %s\n' "$PROXY_NAME"
if confirm; then
  require_tool podman
  # Networked instances run outside the pod; remove by their exact sandbox label.
  mapfile -t containers < <(as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs ps -aq --filter "label=agent-sandbox.id=$SANDBOX_NUM")
  if ((${#containers[@]})); then
    as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs rm -f "${containers[@]}"
  fi
  # Removing the named pod also removes its remaining member containers.
  if as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs pod exists "agent-sandbox-${SANDBOX_NUM}"; then
    as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs pod rm --force "agent-sandbox-${SANDBOX_NUM}"
  fi
  okay 'Named sandbox pod stopped/removed if present'
else echo '[SKIPPED] Containers'; fi

CURRENT_STAGE='stop and remove host log collector'
info '[2] Remove only this sandbox log collector'
show_action "/etc/systemd/system/$LOGGER_UNIT"
show_action "/etc/logrotate.d/agent-sandbox-${SANDBOX_NUM}-proxy"
if confirm; then
  systemctl disable --now "$LOGGER_UNIT" 2>/dev/null || :
  rm -f "/etc/systemd/system/$LOGGER_UNIT" "/etc/logrotate.d/agent-sandbox-${SANDBOX_NUM}-proxy"
  systemctl daemon-reload
  okay 'Sandbox log collector removed'
else echo '[SKIPPED] Log collector'; fi

CURRENT_STAGE='destroy sandbox files'
info '[3] Permanently delete sandbox workspaces and config'
printf '  DELETE (including data and credentials): %s\n' "$SANDBOX_DIR"
printf '  DELETE (ephemeral socket paths):       %s\n' "$RUNTIME_DIR"
printf '  DELETE local SELinux file context rule for this subtree, if present\n'
printf '  This cannot be undone. No shared account or images are deleted.\n'
if confirm; then
  printf 'Type exactly DELETE sandbox %s: ' "$SANDBOX_NUM"
  IFS= read -r phrase || fail 'Confirmation not received.'
  [[ $phrase == "DELETE sandbox $SANDBOX_NUM" ]] || fail 'Deletion confirmation mismatch.'
  [[ ! -L $SANDBOX_DIR && ! -L $RUNTIME_DIR ]] || fail 'Refusing to remove symlink path.'
  [[ ! -e /etc/systemd/system/$LOGGER_UNIT ]] || fail 'Remove the host log collector first (stage 2).'
  mapfile -t remaining < <(as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs ps -aq --filter "label=agent-sandbox.id=$SANDBOX_NUM")
  ((${#remaining[@]} == 0)) || fail 'Sandbox-labelled containers remain; complete stage 1 before deleting data.'
  # Refuse to delete live mount points or active Podman pod.
  if as_agents env HOME="$BASE" podman --cgroup-manager=cgroupfs pod exists "agent-sandbox-${SANDBOX_NUM}"; then
    fail 'Pod remains. Complete stage 1 before destroying files.'
  fi
  rm -rf --one-file-system -- "$SANDBOX_DIR" "$RUNTIME_DIR"
  pattern="${SANDBOX_DIR}/(ro|rw|config)(/.*)?"
  if semanage fcontext -l -C | grep -Fq "$pattern"; then
    semanage fcontext -d "$pattern"
  fi
  okay 'Sandbox workspaces and runtime deleted'
else echo '[SKIPPED] Workspace deletion'; fi

CURRENT_STAGE='delete protected proxy log'
info '[4] Delete host-controlled proxy audit history'
show_action "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
printf '  Remove rotated files for this sandbox only; shared network.log is retained.\n'
if confirm; then
  [[ ! -e /etc/systemd/system/$LOGGER_UNIT ]] || fail 'Remove log collector first.'
  printf 'Type exactly DELETE LOG %s: ' "$SANDBOX_NUM"
  IFS= read -r phrase || fail 'Confirmation not received.'
  [[ $phrase == "DELETE LOG $SANDBOX_NUM" ]] || fail 'Log deletion confirmation mismatch.'
  find "$BASE/control/logs" -maxdepth 1 -type f -name "sandbox-${SANDBOX_NUM}-proxy.log*" -delete
  okay 'Only this sandbox proxy logs removed'
else echo '[SKIPPED] Log deletion'; fi

printf '\nRemoval finished; check any SKIPPED stages above before reusing number %s.\n' "$SANDBOX_NUM"
