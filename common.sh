#!/usr/bin/env bash
# Shared definitions for root-only provisioning scripts.
set -Eeuo pipefail

AGENTS_USER=agents
AGENTS_UID=1888
AGENTS_GID=1888
SHARE_GROUP=agents-share
SHARE_GID=1887
BASE=/home/agents
MIN_SANDBOX=1
MAX_SANDBOX=9999
IMAGE_PREFIX=localhost/agent-sandbox
SETUP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
okay() { printf '[OK] %s\n' "$*"; }
confirm() {
  local reply
  printf '\nProceed with this stage? [y/N] '
  IFS= read -r reply || return 1
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}
require_root() { [[ $EUID == 0 ]] || fail 'Run as root using sudo.'; }
validate_number() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || fail 'Sandbox number must be a positive integer without leading zeros.'
  (( 10#$1 >= MIN_SANDBOX && 10#$1 <= MAX_SANDBOX )) || fail "Sandbox number must be ${MIN_SANDBOX}..${MAX_SANDBOX}."
  SANDBOX_NUM=$((10#$1))
  SANDBOX_DIR="$BASE/sandboxes/$SANDBOX_NUM"
  RUNTIME_DIR="$BASE/runtime/$SANDBOX_NUM"
  PROXY_NAME="agent-sandbox-${SANDBOX_NUM}-proxy"
  LOGGER_UNIT="agent-sandbox-${SANDBOX_NUM}-proxy-log.service"
}
check_identity() {
  local name=$1 num=$2 kind=$3 named existing
  if [[ $kind == group ]]; then
    named=$(getent group "$name" || true)
    existing=$(getent group "$num" || true)
    [[ -z $named || $(cut -d: -f3 <<< "$named") == "$num" ]] || fail "Group $name exists with wrong GID (expected $num)."
    [[ -z $existing || $(cut -d: -f1 <<< "$existing") == "$name" ]] || fail "GID $num belongs to a different group."
  else
    named=$(getent passwd "$name" || true)
    existing=$(getent passwd "$num" || true)
    [[ -z $named || $(cut -d: -f3 <<< "$named") == "$num" ]] || fail "User $name exists with wrong UID (expected $num)."
    [[ -z $existing || $(cut -d: -f1 <<< "$existing") == "$name" ]] || fail "UID $num belongs to a different user."
    if [[ -n $named ]]; then
      [[ $(cut -d: -f4 <<< "$named") == "$AGENTS_GID" ]] || fail "User $name has wrong primary GID."
      [[ $(cut -d: -f6 <<< "$named") == "$BASE" ]] || fail "User $name has wrong home path."
    fi
  fi
}
account_exists() { getent passwd "$AGENTS_USER" >/dev/null 2>&1; }
require_account() {
  check_identity "$AGENTS_USER" "$AGENTS_UID" user
  check_identity "$AGENTS_USER" "$AGENTS_GID" group
  check_identity "$SHARE_GROUP" "$SHARE_GID" group
  account_exists || fail "Host setup required first: missing $AGENTS_USER account."
  getent group "$SHARE_GROUP" >/dev/null || fail "Missing $SHARE_GROUP group."
  if id -nG "$AGENTS_USER" | tr " " "\n" | grep -qx "$SHARE_GROUP"; then
    fail "agents account must not belong to agents-share; that would defeat ro/ protection."
  fi
}
show_action() { local target=$1; if [[ -e $target ]]; then printf '  Update/check: %s\n' "$target"; else printf '  Create:       %s\n' "$target"; fi; }
require_tool() { command -v "$1" >/dev/null || fail "Missing tool $1. Run host_setup.sh packages stage."; }
# Set up an actual systemd user runtime directory for the rootless Podman account.
# Linger keeps the directory available without requiring an interactive login.
ensure_agents_runtime() {
  require_tool loginctl
  require_tool systemctl
  require_tool stat
  require_account

  loginctl enable-linger "$AGENTS_USER"
  systemctl start "user@${AGENTS_UID}.service"
  check_agents_runtime
}

check_agents_runtime() {
  local runtime="/run/user/${AGENTS_UID}" owner mode
  [[ -d $runtime && ! -L $runtime ]] || fail "Missing user runtime directory: $runtime"
  owner=$(stat -c %u -- "$runtime")
  mode=$(stat -c %a -- "$runtime")
  [[ $owner == "$AGENTS_UID" && $mode == 700 ]] ||
    fail "Unsafe runtime directory $runtime: UID $owner, mode $mode (expected $AGENTS_UID and 700)"
}

# Run one controlled command as the unprivileged account, without inheriting
# root's or the invoking sudo user's XDG_RUNTIME_DIR and session variables.
as_agents() {
  # runuser changes UID but preserves cwd. The administrator's working
  # directory may be inaccessible to agents, so enter its own home first.
  # The subshell preserves the calling setup script's working directory.
  (
    cd "$BASE" || fail "Cannot enter $BASE"
    # Non-Podman commands (such as the host ro/ write probe) must also work
    # before stage 5 has created the user runtime directory.
    runuser -u "$AGENTS_USER" -- \
      env -i \
        HOME="$BASE" \
        USER="$AGENTS_USER" \
        LOGNAME="$AGENTS_USER" \
        XDG_RUNTIME_DIR="/run/user/${AGENTS_UID}" \
        PATH=/usr/local/bin:/usr/bin:/bin \
        "$@"
  )
}
render_template() {
  local in=$1 out=$2 number=$3
  sed -e "s|@@NUMBER@@|$number|g" -e "s|@@BASE@@|$BASE|g" "$in" > "$out"
}
