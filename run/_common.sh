#!/usr/bin/env bash
# Shared Podman launcher logic. All launchers execute as the single agents account.
set -Eeuo pipefail
[[ $EUID != 0 ]] || { echo 'ERROR: do not run agent launchers as root' >&2; exit 1; }
[[ $(id -un) == agents ]] || { echo 'ERROR: launch as the agents Linux account' >&2; exit 1; }
# sudo/su may carry the invoking user's XDG_RUNTIME_DIR into this shell.
# Use the runtime directory of the agents account, not the administrator's.
expected_runtime="/run/user/$(id -u)"
[[ -d $expected_runtime && $(stat -c %u -- "$expected_runtime") == "$(id -u)" ]] || {
  echo "ERROR: missing agents runtime directory: $expected_runtime (run host setup stage 5)" >&2
  exit 1
}
export XDG_RUNTIME_DIR="$expected_runtime"
unset DBUS_SESSION_BUS_ADDRESS
[[ ${TOOL:-} == claude || ${TOOL:-} == codex ]] || { echo 'ERROR: TOOL is invalid' >&2; exit 1; }
[[ ${NETWORK_MODE:-} == restricted || ${NETWORK_MODE:-} == networked ]] || { echo 'ERROR: NETWORK_MODE is invalid' >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "Usage: $(basename -- "$0") SANDBOX_NUMBER [TOOL_ARGUMENTS...]" >&2; exit 2; }
number=$1; shift
[[ $number =~ ^[1-9][0-9]*$ ]] && (( 10#$number <= 9999 )) || { echo 'ERROR: sandbox number must be 1..9999, without leading zeros' >&2; exit 2; }
number=$((10#$number))
base=/home/agents
workspace="$base/sandboxes/$number"
conf="$workspace/config/$TOOL-rw"
runtime="$base/runtime/$number"
image="localhost/agent-sandbox-$TOOL:1"
proxy_image=localhost/agent-sandbox-proxy:1
pod="agent-sandbox-$number"
proxy="agent-sandbox-$number-proxy"
podman=(podman --cgroup-manager=cgroupfs)
[[ -d "$workspace/ro" && -d "$workspace/rw" && -d "$conf" && -d "$runtime" ]] || {
  echo "ERROR: missing sandbox $number (run add-agent-sandbox.sh $number first)" >&2; exit 1;
}
# Avoid starting Podman with an accidental default host network on the restricted path.
if [[ $NETWORK_MODE == restricted ]]; then
  [[ -d $runtime ]] || exit 1
  # Keep the host-side launcher lock outside the directory mounted into containers.
  # Podman :z relabels mounted directories; the lock itself must not be relabeled.
  lock_dir="$base/runtime/locks"
  mkdir -p -- "$lock_dir"
  chmod 0700 "$lock_dir"
  exec 9>"$lock_dir/sandbox-$number.lock"
  flock -x 9
  # Never pass FD 9 to Podman/crun/pasta: pasta may reuse it and trigger SELinux
  # writes against our lock file. The shell retains the lock until we release it.
  locked_podman() { "${podman[@]}" "$@" 9>&-; }
  if ! locked_podman pod exists "$pod"; then
    # This pod shares SELinux label and UTS, but *not* network, IPC or PID namespaces.
    locked_podman pod create --name "$pod" --share=uts --infra=true --userns=keep-id:uid=1000,gid=1000 >/dev/null
  fi
  if ! locked_podman container exists "$proxy"; then
    # Only this sidecar has external network access.
    locked_podman run -d --name "$proxy" --pod "$pod" --network=pasta \
      --read-only --read-only-tmpfs=true \
      --tmpfs /tmp:rw,nosuid,nodev,size=128m,mode=1777 \
      --tmpfs /run:rw,nosuid,nodev,size=16m \
      --tmpfs /var/spool/squid:rw,nosuid,nodev,size=32m,mode=1777 \
      --cap-drop=ALL --security-opt=no-new-privileges \
      --label "agent-sandbox.id=$number" --label agent-sandbox.tool=proxy \
      --env "SANDBOX_NUM=$number" \
      --volume "$runtime:/proxy-sockets:rw,z" \
      "$proxy_image" >/dev/null
  elif [[ $(locked_podman inspect --format '{{.State.Running}}' "$proxy") != true ]]; then
    locked_podman start "$proxy" >/dev/null
  fi
  # Ensure the relay sockets are ready before invoking the agent.
  socket="$runtime/$TOOL.sock"
  ready=false
  for i in {1..60}; do
    if [[ -S $socket && $(locked_podman inspect --format '{{.State.Running}}' "$proxy") == true ]]; then ready=true; break; fi
    sleep 0.1
  done
  [[ $ready == true ]] || { echo 'ERROR: proxy sidecar did not create its socket; check podman logs' >&2; exit 1; }
  flock -u 9
  exec 9>&-
fi

interactive=(--interactive)
[[ -t 0 && -t 1 ]] && interactive+=(--tty)
args=(run --rm "${interactive[@]}"
  --user=1000:1000
  --read-only --read-only-tmpfs=false
  --tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777
  --tmpfs /run:rw,nosuid,nodev,size=16m
  --cap-drop=ALL --security-opt=no-new-privileges
  --label "agent-sandbox.id=$number" --label "agent-sandbox.tool=$TOOL"
  --volume "$workspace/ro:/workspace/ro:ro"
  --volume "$workspace/rw:/workspace/rw:rw,z"
  --volume "$conf:/config/$TOOL-rw:rw,z"
  --workdir /workspace/rw)
if [[ $NETWORK_MODE == networked ]]; then
  echo "Network: unrestricted; host audit is enabled only if configured. sandbox=$number tool=$TOOL" >&2
  exec "${podman[@]}" "${args[@]}" --userns=keep-id:uid=1000,gid=1000 --network=pasta "$image" "$@"
fi
args+=(--pod "$pod" --network=none
  --volume "$runtime:/proxy-sockets:ro"
  --env HTTPS_PROXY=http://127.0.0.1:3128
  --env HTTP_PROXY=http://127.0.0.1:3128
  --env https_proxy=http://127.0.0.1:3128
  --env http_proxy=http://127.0.0.1:3128
  --env ALL_PROXY=http://127.0.0.1:3128
  --env all_proxy=http://127.0.0.1:3128
  --env NO_PROXY= --env no_proxy=
  --entrypoint /bin/bash)
[[ $TOOL != claude ]] || args+=(--env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
# Local HTTP proxy exists only inside agent network namespace. All TCP traffic
# from it is relayed over the mounted Unix socket to the networked sidecar.
exec "${podman[@]}" "${args[@]}" "$image" -c '
  set -Eeuo pipefail
  tool=$1; shift
  socket="/proxy-sockets/$tool.sock"
  [[ -S $socket ]] || { echo "ERROR: proxy socket unavailable: $socket" >&2; exit 1; }
  socat TCP4-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$socket" &
  relay=$!
  trap '\''kill "$relay" 2>/dev/null || :'\'' EXIT
  for i in {1..50}; do
    if (echo > /dev/tcp/127.0.0.1/3128) 2>/dev/null; then break; fi
    sleep 0.1
  done
  kill -0 "$relay" || { echo "ERROR: local relay failed" >&2; exit 1; }
  if [[ ${1:-} == --check-network ]]; then
    case "$tool" in claude) allowed=api.anthropic.com;; codex) allowed=api.openai.com;; esac
    allowed_code=$(curl --silent --show-error --max-time 20 --output /dev/null --write-out "%{http_connect}" "https://$allowed/" || true)
    [[ $allowed_code == 200 ]] || { echo "FAIL allowed domain $allowed (CONNECT $allowed_code)" >&2; exit 1; }
    echo "PASS: proxy permits $allowed"
    denied_code=$(curl --silent --max-time 10 --output /dev/null --write-out "%{http_connect}" https://example.com/ || true)
    [[ $denied_code != 200 ]] || { echo "FAIL: proxy allowed example.com" >&2; exit 1; }
    echo "PASS: proxy denies example.com (CONNECT $denied_code)"
    if curl --noproxy "*" --silent --connect-timeout 3 --max-time 5 --output /dev/null https://1.1.1.1/; then
      echo "FAIL: direct internet worked" >&2; exit 1
    fi
    echo "PASS: direct internet unavailable"
    exit 0
  fi
  exec "$tool" "$@"
' agent-proxy "$TOOL" "$@"
