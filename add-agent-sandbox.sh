#!/usr/bin/env bash
# Add a numbered logical sandbox under the shared, unprivileged agents account.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root
[[ $# == 1 ]] || fail 'Usage: add-agent-sandbox.sh NUMBER'
validate_number "$1"
CURRENT_STAGE=initialization
trap 'printf "ERROR: add-agent-sandbox.sh stopped during %s (line %s, exit %s).\n" "$CURRENT_STAGE" "$LINENO" "$?" >&2' ERR
require_account
printf 'ADD AGENT SANDBOX %s\n  Host account: %s (%s)\n  Filesystem: %s\n  Runtime sockets: %s\n' "$SANDBOX_NUM" "$AGENTS_USER" "$AGENTS_UID" "$SANDBOX_DIR" "$RUNTIME_DIR"

CURRENT_STAGE='sandbox directories and ACLs'
info '[1] Sandbox workspace and permissions'
for p in "$SANDBOX_DIR" "$SANDBOX_DIR/ro" "$SANDBOX_DIR/rw" "$SANDBOX_DIR/config" "$SANDBOX_DIR/config/claude-rw" "$SANDBOX_DIR/config/codex-rw" "$RUNTIME_DIR"; do show_action "$p"; done
printf '  ro/: root:agents, agents read-only, agents-share writable via ACL\n'
printf '  rw/: agents-owned, agents-share writable via ACL\n'
printf '  config/: agents-owned, only mounted into the matching runtime\n'
printf '  SELinux: label ro/rw/config for container volumes from the host\n'
if confirm; then
  require_tool setfacl; require_tool semanage; require_tool restorecon
  [[ ! -L $SANDBOX_DIR && ! -L $RUNTIME_DIR ]] || fail 'Refusing symlink in managed sandbox paths.'
  install -d -m 0751 -o root -g root "$SANDBOX_DIR"
  install -d -m 2750 -o root -g "$AGENTS_USER" "$SANDBOX_DIR/ro"
  install -d -m 2770 -o "$AGENTS_USER" -g "$AGENTS_USER" "$SANDBOX_DIR/rw"
  install -d -m 0700 -o "$AGENTS_USER" -g "$AGENTS_USER" "$SANDBOX_DIR/config" "$SANDBOX_DIR/config/claude-rw" "$SANDBOX_DIR/config/codex-rw" "$RUNTIME_DIR"
  # Apply ACLs to the roots and establish sane defaults for new content.
  setfacl -m "g:${SHARE_GROUP}:rwx,m::rwx,o::---" "$SANDBOX_DIR/ro" "$SANDBOX_DIR/rw"
  setfacl -m "d:g:${AGENTS_USER}:r-x,d:g:${SHARE_GROUP}:rwx,d:m::rwx,d:o::---" "$SANDBOX_DIR/ro"
  setfacl -m "d:g:${AGENTS_USER}:rwx,d:g:${SHARE_GROUP}:rwx,d:m::rwx,d:o::---" "$SANDBOX_DIR/rw"
  # Re-running preserves children, but normalizes root dirs and ACLs only.
  chmod g+s "$SANDBOX_DIR/ro" "$SANDBOX_DIR/rw"
  # Persistent Fedora fcontext rules: don't ask rootless Podman to relabel a root-owned ro/.
  pattern="${SANDBOX_DIR}/(ro|rw|config)(/.*)?"
  if ! semanage fcontext -l -C | grep -Fq "$pattern"; then
    semanage fcontext -a -t container_file_t "$pattern"
  fi
  restorecon -R "$SANDBOX_DIR/ro" "$SANDBOX_DIR/rw" "$SANDBOX_DIR/config"
  # Fail immediately if the account can create a file in host-ro/.
  probe="$SANDBOX_DIR/ro/.agent-write-probe-$$"
  if as_agents touch "$probe" 2>/dev/null; then
    rm -f "$probe"
    fail 'SECURITY FAILURE: agents can write into ro/ on the host.'
  fi
  okay 'Sandbox filesystem ready; existing project contents preserved'
else echo '[SKIPPED] Sandbox directories'; fi

CURRENT_STAGE='proxy log collector'
info '[2] Host-protected proxy audit output'
show_action "/etc/systemd/system/$LOGGER_UNIT"
show_action "/etc/logrotate.d/agent-sandbox-${SANDBOX_NUM}-proxy"
show_action "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
printf '  Proxy container emits Squid request logs on stdout; root-managed systemd copies them here.\n'
printf '  Agent containers cannot mount or change control/logs.\n'
if confirm; then
  [[ -d $SANDBOX_DIR ]] || fail 'Create sandbox directory first.'
  [[ -x /usr/local/libexec/agent-sandbox-proxy-log.sh ]] || fail 'Host setup stage 3 required (log collector missing).'
  render_template "$SETUP_DIR/templates/proxy-log.service.in" "/etc/systemd/system/$LOGGER_UNIT" "$SANDBOX_NUM"
  render_template "$SETUP_DIR/templates/proxy-log.logrotate.in" "/etc/logrotate.d/agent-sandbox-${SANDBOX_NUM}-proxy" "$SANDBOX_NUM"
  chmod 0644 "/etc/systemd/system/$LOGGER_UNIT" "/etc/logrotate.d/agent-sandbox-${SANDBOX_NUM}-proxy"
  touch "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
  chown root:"$SHARE_GROUP" "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
  chmod 0640 "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
  restorecon "$BASE/control/logs/sandbox-${SANDBOX_NUM}-proxy.log"
  systemctl daemon-reload
  systemctl enable --now "$LOGGER_UNIT"
  systemctl is-active --quiet "$LOGGER_UNIT" || fail "Proxy log collector $LOGGER_UNIT failed."
  okay "Protected proxy log collector installed: $LOGGER_UNIT"
else echo '[SKIPPED] Proxy log collector'; fi

info 'Sandbox setup complete'
printf 'Launch as agents:\n  %s/run/claude.sh %s\n  %s/run/codex.sh %s\n' "$BASE" "$SANDBOX_NUM" "$BASE" "$SANDBOX_NUM"
printf 'Unrestricted launchers: %s/run/{claude,codex}-networked.sh %s\n' "$BASE" "$SANDBOX_NUM"
printf 'For a user in agents-share, create symlinks if desired:\n'
printf '  ln -s %s/ro ~/agent-sandbox-%s-ro\n' "$SANDBOX_DIR" "$SANDBOX_NUM"
printf '  ln -s %s/rw ~/agent-sandbox-%s-rw\n' "$SANDBOX_DIR" "$SANDBOX_NUM"
printf 'Root-controlled logs:\n  %s/control/logs/sandbox-%s-proxy.log\n  %s/control/logs/network.log\n' "$BASE" "$SANDBOX_NUM" "$BASE"
