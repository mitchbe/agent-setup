#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
: "${SANDBOX_NUM:?SANDBOX_NUM required}"
[[ -d /proxy-sockets ]] || { echo 'ERROR: /proxy-sockets not mounted' >&2; exit 1; }
# Each socket is on a dedicated, bind-mounted directory writable by the proxy
# process, but mounted read-only in the agents' containers.
socat UNIX-LISTEN:/proxy-sockets/claude.sock,fork,unlink-early,mode=0600 TCP4:127.0.0.1:3128 &
claude_relay=$!
socat UNIX-LISTEN:/proxy-sockets/codex.sock,fork,unlink-early,mode=0600 TCP4:127.0.0.1:3129 &
codex_relay=$!
cleanup() { kill "$claude_relay" "$codex_relay" "${squid_pid:-}" 2>/dev/null || :; wait 2>/dev/null || :; }
trap cleanup EXIT INT TERM
squid -N -f /etc/squid/agent-sandbox.conf &
squid_pid=$!
# Any failed component terminates the sidecar; agent launches then fail closed.
wait -n "$claude_relay" "$codex_relay" "$squid_pid"
