#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
echo 'Shell syntax:'
for f in ./*.sh ./run/*.sh ./proxy/*.sh; do bash -n "$f"; printf '  OK %s\n' "$f"; done
# Rootless scripts should not create arbitrary SELinux firewall exceptions.
! grep -REn 'label=disable|setenforce 0|audit2allow|--privileged|--network=host' run/ proxy/ *.sh
echo 'Proxy launch mode checks:'
grep -q -- '--share=uts' run/_common.sh
grep -q -- '--network=none' run/_common.sh
grep -q -- '--network=pasta' run/_common.sh
echo 'Host launcher lock checks:'
grep -Fq 'lock_dir="$base/runtime/locks"' run/_common.sh
grep -Fq 'locked_podman() { "${podman[@]}" "$@" 9>&-; }' run/_common.sh
grep -Fq 'exec 9>&-' run/_common.sh
! grep -Fq '"$runtime/start.lock"' run/_common.sh
echo 'Host ACL checks:' 
grep -q 'g:${SHARE_GROUP}:rwx' add-agent-sandbox.sh
grep -q 'd:g:${AGENTS_USER}:r-x' add-agent-sandbox.sh
echo 'Rootless Podman runtime checks:'
grep -Fq 'env -i' common.sh
grep -Fq 'cd "$BASE" || fail' common.sh
grep -Fq 'ensure_agents_runtime' host_setup.sh
grep -Fq 'XDG_RUNTIME_DIR="/run/user/${AGENTS_UID}"' common.sh
grep -Fq 'expected_runtime="/run/user/$(id -u)"' run/_common.sh
grep -Fq '"$BASE/build"' host_setup.sh
grep -Fq '"$BASE/build/Containerfile.$tool"' host_setup.sh
echo '  OK: build and launch environment checks'
echo 'Positive sandbox numbering tests:'
for n in 0 00 01 -1 nope 10000; do
  if (source ./common.sh; validate_number "$n") >/dev/null 2>&1; then
    printf 'FAIL accepted sandbox number %s\n' "$n"; exit 1
  fi
done
for n in 1 2 9999; do (source ./common.sh; validate_number "$n"); done
! grep -R '@@NUMBER@@' README.md run/ proxy/ >/dev/null
printf 'OK: validation complete (no Fedora execution performed)\n'
