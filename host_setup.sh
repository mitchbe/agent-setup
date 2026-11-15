#!/usr/bin/env bash
# Shared Fedora host preparation; run once, rerun stages selectively.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root
CURRENT_STAGE=initialization
trap 'printf "ERROR: host_setup.sh stopped during %s (line %s, exit %s).\n" "$CURRENT_STAGE" "$LINENO" "$?" >&2' ERR

SHARE_WITH=''
case $# in
  0) ;;
  2) [[ $1 == --share-with ]] || fail 'Usage: host_setup.sh [--share-with USER]'; SHARE_WITH=$2 ;;
  *) fail 'Usage: host_setup.sh [--share-with USER]' ;;
esac
if [[ -n $SHARE_WITH ]]; then
  [[ $SHARE_WITH =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'Invalid --share-with username.'
  getent passwd "$SHARE_WITH" >/dev/null || fail "Share user does not exist: $SHARE_WITH"
  [[ $SHARE_WITH != "$AGENTS_USER" ]] || fail 'Do not add agents itself to agents-share.'
fi
# Fail before any changes if identities disagree with fixed IDs.
check_identity "$AGENTS_USER" "$AGENTS_GID" group
check_identity "$SHARE_GROUP" "$SHARE_GID" group
check_identity "$AGENTS_USER" "$AGENTS_UID" user

printf 'HOST SETUP (Fedora)\n  Account: %s UID %s, primary group GID %s\n  Sharing group: %s GID %s\n  Home: %s\n' "$AGENTS_USER" "$AGENTS_UID" "$AGENTS_GID" "$SHARE_GROUP" "$SHARE_GID" "$BASE"
[[ -z $SHARE_WITH ]] || printf '  Share with: %s\n' "$SHARE_WITH"

CURRENT_STAGE='host packages'
info '[1] Host packages'
printf '  Install/verify: podman, nftables, tcpdump, logrotate, acl, policycoreutils-python-utils, curl, tar, git\n'
if confirm; then
  dnf -y install podman nftables tcpdump logrotate acl policycoreutils-python-utils curl tar git
  okay 'Packages available'
else echo '[SKIPPED] Host packages'; fi

CURRENT_STAGE='host identities'
info '[2] Shared account and groups'
for pair in "$AGENTS_USER:$AGENTS_GID" "$SHARE_GROUP:$SHARE_GID"; do
  name=${pair%%:*}; gid=${pair#*:}
  if getent group "$name" >/dev/null; then printf '  Reuse: group %s (exists; GID %s)\n' "$name" "$gid"; else printf '  Create: group %s (GID %s)\n' "$name" "$gid"; fi
done
if account_exists; then printf '  Reuse: user agents (exists; UID %s)\n' "$AGENTS_UID"; else printf '  Create: user agents (UID %s; home %s)\n' "$AGENTS_UID" "$BASE"; fi
[[ -z $SHARE_WITH ]] || printf '  Ensure membership: %s in %s (not agents)\n' "$SHARE_WITH" "$SHARE_GROUP"
if confirm; then
  getent group "$AGENTS_USER" >/dev/null || groupadd -g "$AGENTS_GID" "$AGENTS_USER"
  getent group "$SHARE_GROUP" >/dev/null || groupadd -g "$SHARE_GID" "$SHARE_GROUP"
  if ! account_exists; then useradd -u "$AGENTS_UID" -g "$AGENTS_GID" -d "$BASE" -m -s /bin/bash "$AGENTS_USER"; fi
  [[ -z $SHARE_WITH ]] || usermod -aG "$SHARE_GROUP" "$SHARE_WITH"
  [[ $(id -u "$AGENTS_USER") == "$AGENTS_UID" ]] || fail 'Account UID did not match after creation.'
  if id -nG "$AGENTS_USER" | tr ' ' '\n' | grep -qx "$SHARE_GROUP"; then fail 'agents account must not belong to agents-share'; fi
  okay 'Shared identities ready'
else echo '[SKIPPED] Shared identities'; fi

CURRENT_STAGE='protected host filesystem'
info '[3] Home and host-managed paths'
printf '  Create/check: %s (root-owned, not writable by agents)\n' "$BASE"
printf '  Create/check: %s/control/logs (root-owned)\n' "$BASE"
printf '  Create/check: %s/sandboxes (root-owned)\n' "$BASE"
printf '  Create/check: %s/runtime (agents-owned)\n' "$BASE"
printf '  Create/check: %s/{run,.local,.config,.cache} (agents-owned as needed)\n' "$BASE"
printf '  Create/check: %s/build (root-owned, read-only to agents)\n' "$BASE"
printf '  Install: %s/build/Containerfile.{claude,codex,proxy} from setup/\n' "$BASE"
printf '  Install: %s/build/proxy/{squid.conf,start-proxy.sh} from setup/proxy/\n' "$BASE"
printf '  Install: %s/run/*.sh from setup/run/\n' "$BASE"
printf '  Install: %s/README.md from setup/README.agents.md\n' "$BASE"
printf '  Install: /usr/local/libexec/agent-sandbox-proxy-log.sh\n'
if confirm; then
  require_account
  install -d -m 0755 -o root -g root "$BASE"
  install -d -m 0751 -o root -g root "$BASE/sandboxes"
  install -d -m 0750 -o root -g "$SHARE_GROUP" "$BASE/control" "$BASE/control/logs"
  install -d -m 0700 -o "$AGENTS_USER" -g "$AGENTS_USER" "$BASE/runtime" "$BASE/.config" "$BASE/.cache" "$BASE/.local" "$BASE/.local/share" "$BASE/.local/share/containers"
  install -d -m 0755 -o root -g root "$BASE/run"
  # Build inputs must be readable by agents even when setup/ lives in a
  # private administrator home. This staging tree is never agent-writable.
  install -d -m 0750 -o root -g "$AGENTS_USER" "$BASE/build" "$BASE/build/proxy"
  for tool in claude codex proxy; do
    install -m 0640 -o root -g "$AGENTS_USER" \
      "$SETUP_DIR/Containerfile.$tool" "$BASE/build/Containerfile.$tool"
  done
  install -m 0640 -o root -g "$AGENTS_USER" \
    "$SETUP_DIR/proxy/squid.conf" "$BASE/build/proxy/squid.conf"
  install -m 0640 -o root -g "$AGENTS_USER" \
    "$SETUP_DIR/proxy/start-proxy.sh" "$BASE/build/proxy/start-proxy.sh"
  for f in "$SETUP_DIR"/run/*.sh; do
    install -m 0555 -o root -g root "$f" "$BASE/run/$(basename "$f")"
  done
  install -m 0444 -o root -g root "$SETUP_DIR/README.agents.md" "$BASE/README.md"
  require_tool semanage; require_tool restorecon
  log_pattern="${BASE}/control/logs(/.*)?"
  if ! semanage fcontext -l -C | grep -Fq "$log_pattern"; then
    semanage fcontext -a -t var_log_t "$log_pattern"
  fi
  restorecon -R "$BASE/control/logs"
  install -d -m 0755 /usr/local/libexec
  install -m 0555 -o root -g root "$SETUP_DIR/proxy-log-collector.sh" /usr/local/libexec/agent-sandbox-proxy-log.sh
  # Important: making directories root-owned prevents replacement of control/ by agents.
  chown root:root "$BASE" "$BASE/sandboxes"
  chmod 0755 "$BASE"; chmod 0751 "$BASE/sandboxes"
  okay 'Protected host filesystem ready'
else echo '[SKIPPED] Host filesystem'; fi

CURRENT_STAGE='network auditing'
info '[4] Host-side outbound connection logging'
show_action /etc/nftables/agents-audit.nft
show_action /etc/systemd/system/agents-audit.service
show_action /etc/systemd/system/agents-network-log.service
show_action /etc/logrotate.d/agents-network-log
printf '  Log: %s/control/logs/network.log\n' "$BASE"
printf '  Note: logs agent account traffic collectively, not individual sandbox attribution.\n'
if confirm; then
  require_account; require_tool nft; require_tool tcpdump
  install -d -m 0755 /etc/nftables
  install -m 0644 "$SETUP_DIR/templates/host-audit.nft" /etc/nftables/agents-audit.nft
  install -m 0644 "$SETUP_DIR/templates/host-audit.service" /etc/systemd/system/agents-audit.service
  install -m 0644 "$SETUP_DIR/templates/host-network-log.service" /etc/systemd/system/agents-network-log.service
  install -m 0644 "$SETUP_DIR/templates/host-network-log.logrotate" /etc/logrotate.d/agents-network-log
  touch "$BASE/control/logs/network.log"
  chown root:"$SHARE_GROUP" "$BASE/control/logs/network.log"
  chmod 0640 "$BASE/control/logs/network.log"
  systemctl daemon-reload
  systemctl enable --now agents-audit.service
  systemctl enable --now agents-network-log.service
  systemctl restart agents-audit.service agents-network-log.service
  systemctl is-active --quiet agents-network-log.service || fail 'Network logging failed to start'
  okay 'Network audit installed and active'
else echo '[SKIPPED] Network audit'; fi

CURRENT_STAGE='shared image builds'
info '[5] Build shared rootless images'
printf '  As %s, build images into one Podman store:\n' "$AGENTS_USER"
printf '    localhost/agent-sandbox-claude:1   <- %s/build/Containerfile.claude\n' "$BASE"
printf '    localhost/agent-sandbox-codex:1    <- %s/build/Containerfile.codex\n' "$BASE"
printf '    localhost/agent-sandbox-proxy:1    <- %s/build/Containerfile.proxy\n' "$BASE"
printf '  Ensure: loginctl linger enabled for agents, systemd user manager running\n'
printf '  Runtime: /run/user/%s (agents-owned, 0700)\n' "$AGENTS_UID"
printf '  Image store: %s/.local/share/containers/storage\n' "$BASE"
printf '  No container storage configuration is changed.\n'
if confirm; then
  require_account; require_tool podman
  [[ -r $BASE/build/Containerfile.claude && -r $BASE/build/Containerfile.codex && -r $BASE/build/Containerfile.proxy && -r $BASE/build/proxy/squid.conf && -r $BASE/build/proxy/start-proxy.sh ]] ||
    fail 'Build inputs missing. Complete stage 3 first.'
  ensure_agents_runtime
  okay "Rootless user runtime ready: /run/user/${AGENTS_UID}"
  as_agents podman --cgroup-manager=cgroupfs info --format '{{.Store.GraphRoot}}'
  for tool in claude codex proxy; do
    as_agents podman --cgroup-manager=cgroupfs build \
      --tag "$IMAGE_PREFIX-$tool:1" \
      --file "$BASE/build/Containerfile.$tool" \
      "$BASE/build"
    okay "Built $IMAGE_PREFIX-$tool:1"
  done
else echo '[SKIPPED] Shared image builds'; fi

info 'Host setup complete'
printf 'Next: sudo %s/add-agent-sandbox.sh 1\n' "$SETUP_DIR"
if [[ -n $SHARE_WITH ]]; then
  printf 'After logging in again as %s, symlink commands for sandbox 1:\n' "$SHARE_WITH"
  printf '  ln -s %s/sandboxes/1/ro ~/agent-sandbox-1-ro\n' "$BASE"
  printf '  ln -s %s/sandboxes/1/rw ~/agent-sandbox-1-rw\n' "$BASE"
fi
