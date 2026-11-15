# Agent sandboxes — Fedora/Podman setup

This installs a **single** unprivileged Linux account (`agents`, UID 1888, primary group `agents`, GID 1886), supporting multiple numbered, logically isolated AI workspaces (`sandboxes/1`, `sandboxes/2`, etc.). It uses a separate `agents-share` group (GID 1887) for host-side access by your personal account. The `agents` user is **not** a member of `agents-share`.

Each sandbox can run multiple Claude Code and Codex CLI instances concurrently. Instances in one sandbox share `rw/` by design; sandbox containers can only see their own mounts. An escape to the host `agents` UID can compromise other sandboxes' writable data and Podman storage, but not root-protected audit records or `ro/` content under correctly maintained permissions.

## Installation

Use an administrator account on Fedora. Extract this directory and run:

```bash
sudo ./setup/host_setup.sh --share-with YOUR_PERSONAL_USERNAME
sudo ./setup/add-agent-sandbox.sh 1
sudo ./setup/add-agent-sandbox.sh 2      # optional
```

Host setup enables lingering for the `agents` user during image builds and starts `user@1888.service`, creating `/run/user/1888` for temporary Podman runtime state. Host teardown disables linger and stops that user manager before deleting the account. `/home/agents/build/` holds a root-owned read-only copy of the build inputs, so builds work even if your administrator home is private.

Each script describes the **exact planned files and directories** and asks Y/N at each stage. Stages are independent where possible, but a skipped prerequisite must be completed before a dependent stage. Reruns preserve workspace contents. These scripts do not migrate previous agent1/agent-sandbox-N account installations; remove or back up the old configuration separately.

Log into the `agents` account (or use `sudo -iu agents` when your admin policy allows) and launch:

```bash
/home/agents/run/claude.sh 1 --check-network
/home/agents/run/codex.sh 1 --check-network
/home/agents/run/claude.sh 1
/home/agents/run/codex.sh 1
```

`claude.sh` and `codex.sh` use the restricted network. `claude-networked.sh` and `codex-networked.sh` allow normal internet access. The restricted launch starts a network-enabled Squid **sidecar in a Podman pod with no shared network namespace**; agent containers use `--network=none` and reach the sidecar using a bind-mounted Unix socket. SELinux labels are shared by containers in the same pod, but not between pods. Do not change `--share=uts` to Podman's default shared namespaces, which would include `net`.

Only `api.anthropic.com:443` is allowed for Claude; `api.openai.com`, `chatgpt.com` and `auth.openai.com` on 443 for Codex. These are deliberately minimal and may need revisiting if authentication uses additional hosts. The proxy blocks non-CONNECT requests and private-address destinations.

## Storage and permissions

```text
/home/agents/                          root:root (not agent-writable)
├── README.md                          installed from README.agents.md
├── run/                               root-owned launch scripts
├── control/logs/                      root-owned audit logs
│   ├── network.log                    outgoing connection metadata for agents UID
│   └── sandbox-1-proxy.log            Squid request/diagnostic output
├── runtime/1/                         agents-writable sockets and locks
└── sandboxes/1/                       root-owned parent
    ├── ro/                            root:agents, agents can read only
    ├── rw/                            agents can read/write
    └── config/
        ├── claude-rw/                 only mounted into Claude
        └── codex-rw/                  only mounted into Codex
```

`agents-share` gets read/write ACL access to each `ro/` and `rw/`, but not to tool credentials or runtime internals. The read-only mount is backed by host ownership/ACL protection: an escaped process running as `agents` cannot normally alter reference contents. The installer also registers SELinux labels for the root-owned reference directories and the protected log directory. It sets **default** ACLs; if you copy files using ownership-preserving tools or override ACLs, verify the new files retain the intended permissions. The `rw/` subtree is intentionally writable to multiple agents in one sandbox.

As a member of `agents-share`, after logging in again:

```bash
ln -s /home/agents/sandboxes/1/ro ~/agent-sandbox-1-ro
ln -s /home/agents/sandboxes/1/rw ~/agent-sandbox-1-rw
```

## Host logs and log rotation

- `/home/agents/control/logs/network.log`: root-controlled NFLOG/tcpdump records for network connections owned by the `agents` UID. This is **account-wide**, not attributable to one sandbox.
- `/home/agents/control/logs/sandbox-N-proxy.log`: root-controlled copy of proxy container output for sandbox N; includes successful and denied Squid requests.
- `/etc/logrotate.d/agents-network-log` and `/etc/logrotate.d/agent-sandbox-N-proxy`: rotate via the host's normal logrotate schedule, not when an agent starts. `copytruncate` can lose a few records during rotation; this is a local audit aid, not a tamper-proof remote log system.

The host `agents` UID cannot write the existing root-owned log files, but it can stop or manipulate its own rootless containers, so it could suppress or forge *future proxy log events* after a host-account compromise. Protected files prevent deletion of prior records; they do not provide cryptographic authenticity.

## Removal

```bash
sudo ./setup/remove-agent-sandbox.sh 2
# After removing every numbered sandbox, optionally:
sudo ./setup/host_teardown.sh
```

Removal stages have separate confirmations. Workspace and audit-log deletion additionally require typed confirmation. `host_teardown.sh` refuses to remove the shared account while numbered sandbox directories remain. Host packages and `agents-share` are deliberately not uninstalled.

## File installation reference

| Source under `setup/` | Destination / use |
|---|---|
| `host_setup.sh`, `add-agent-sandbox.sh`, `remove-agent-sandbox.sh`, `host_teardown.sh`, `common.sh` | Administrator-run scripts; retained in the setup directory |
| `Containerfile.claude`, `Containerfile.codex`, `Containerfile.proxy` | Copied into `/home/agents/build/` as root-owned, agents-readable inputs; built into the shared rootless Podman image store |
| `proxy/squid.conf`, `proxy/start-proxy.sh` | Copied into `localhost/agent-sandbox-proxy:1` during image build |
| `run/_common.sh`, `run/claude.sh`, `run/codex.sh`, `run/claude-networked.sh`, `run/codex-networked.sh` | `/home/agents/run/` (read-only to agents) |
| `README.agents.md` | `/home/agents/README.md` |
| `proxy-log-collector.sh` | `/usr/local/libexec/agent-sandbox-proxy-log.sh` |
| `templates/proxy-log.service.in` | `/etc/systemd/system/agent-sandbox-N-proxy-log.service` |
| `templates/proxy-log.logrotate.in` | `/etc/logrotate.d/agent-sandbox-N-proxy` |
| `templates/host-audit.nft` | `/etc/nftables/agents-audit.nft` |
| `templates/host-audit.service` | `/etc/systemd/system/agents-audit.service` |
| `templates/host-network-log.service` | `/etc/systemd/system/agents-network-log.service` |
| `templates/host-network-log.logrotate` | `/etc/logrotate.d/agents-network-log` |
| `tests/validate.sh` | Static syntax and safety checks; remains in setup directory |

## Testing and status

`bash ./setup/tests/validate.sh` verifies scripts and naming conventions without changing the host. The restricted launcher `--check-network` verifies permitted HTTP CONNECT, denied unrelated HTTPS and blocked direct egress. Read `podman logs agent-sandbox-N-proxy` if the sidecar fails. On Fedora with enforcing SELinux, verify both the Unix socket connection and the expected denial of direct networking before authenticating either tool.

Do not rely on restricted mode until its acceptance tests pass on your Fedora host. This is rootless container isolation, not a VM or protection against kernel compromise.

## SELinux: proxy sidecar startup

Restricted launchers acquire a host-side lock in `/home/agents/runtime/locks/`.
The lock is not mounted in the proxy container, and the launcher's file descriptor
is closed in Podman subprocesses. This avoids `pasta_t` write denials on the lock.
If proxy startup still fails, inspect `podman logs agent-sandbox-N-proxy`
and recent SELinux AVC denials before changing any host policy.
