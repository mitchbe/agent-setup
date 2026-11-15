#!/usr/bin/env bash
# Remove shared host infrastructure after all logical sandboxes are removed.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root
[[ $# == 0 ]] || fail 'Usage: host_teardown.sh'
require_account
if find "$BASE/sandboxes" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
  fail 'Logical sandboxes remain. Remove each with remove-agent-sandbox.sh first.'
fi
printf 'HOST TEARDOWN: %s UID %s\nExisting agent account, shared images and all its state may be deleted.\n' "$AGENTS_USER" "$AGENTS_UID"
info '[1] Stop and remove host network auditing'
for p in /etc/systemd/system/agents-audit.service /etc/systemd/system/agents-network-log.service /etc/nftables/agents-audit.nft /etc/logrotate.d/agents-network-log; do show_action "$p"; done
if confirm; then
  systemctl disable --now agents-network-log.service agents-audit.service 2>/dev/null || :
  rm -f /etc/systemd/system/agents-audit.service /etc/systemd/system/agents-network-log.service /etc/nftables/agents-audit.nft /etc/logrotate.d/agents-network-log
  systemctl daemon-reload
  okay 'Host audit services removed'
else echo '[SKIPPED] Host audit'; fi
info '[2] Delete shared account and all remaining home data'
printf '  Permanently remove: %s account, its rootless image store, runtime, logs and home\n' "$AGENTS_USER"
printf '  Keep agents-share group and DNF packages (may be used by others).\n'
printf '  Disable linger and stop the agents user manager (may stop user services).\n'
printf '  Refuse if any logical sandboxes or processes remain afterward.\n'
if confirm; then
  printf 'Type exactly DELETE HOST AGENTS: '
  IFS= read -r answer || fail 'No confirmation'
  [[ $answer == 'DELETE HOST AGENTS' ]] || fail 'Confirmation mismatch.'
  if find "$BASE/sandboxes" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then fail 'Sandboxes remain'; fi
  [[ ! -e /etc/systemd/system/agents-audit.service && ! -e /etc/systemd/system/agents-network-log.service ]] || fail 'Remove host audit services (stage 1) before account deletion.'
  # Linger was enabled by host setup to provide /run/user/1888. End the
  # user manager before checking for remaining processes or deleting the UID.
  # Stopping user@ can terminate user services: this is an explicit teardown.
  if command -v loginctl >/dev/null; then
    loginctl disable-linger "$AGENTS_USER"
  fi
  if systemctl is-active --quiet "user@${AGENTS_UID}.service"; then
    systemctl stop "user@${AGENTS_UID}.service"
  fi
  if pgrep -u "$AGENTS_UID" >/dev/null; then
    ps -u "$AGENTS_USER" -o pid,comm,args >&2 || :
    fail 'agents account still has running processes; stop them first'
  fi
  # Do not blindly replace an unrelated host path.
  [[ -d $BASE && ! -L $BASE ]] || fail 'Home directory is not the expected real directory.'
  log_pattern="${BASE}/control/logs(/.*)?"
  if semanage fcontext -l -C | grep -Fq "$log_pattern"; then
    semanage fcontext -d "$log_pattern"
  fi
  userdel "$AGENTS_USER"
  rm -rf --one-file-system -- "$BASE"
  if getent group "$AGENTS_USER" >/dev/null; then groupdel "$AGENTS_USER"; fi
  rm -f /usr/local/libexec/agent-sandbox-proxy-log.sh
  okay 'Shared account and home removed'
else echo '[SKIPPED] Account and home deletion'; fi
printf '\nHost teardown finished.\n'
