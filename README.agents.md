# Agent sandbox host

This is the **shared Linux account** for rootless Podman agent execution. Individual sandboxes are under `sandboxes/N/`.

- `run/claude.sh N` / `run/codex.sh N`: API-restricted mode, proxy sidecar, no direct internet.
- `run/claude-networked.sh N` / `run/codex-networked.sh N`: unrestricted network mode.
- `sandboxes/N/ro/`: reference material; read-only to the `agents` account and all agent containers.
- `sandboxes/N/rw/`: agent-writable workspace.
- `sandboxes/N/config/{claude-rw,codex-rw}/`: tool-specific credentials and state.
- `runtime/N/`: sockets and startup locks; **not** audit log storage.
- `control/logs/network.log`: host-collected outbound connection metadata for the shared account.
- `control/logs/sandbox-N-proxy.log`: host-collected proxy output for sandbox N.

Logs, control files and the top-level home directory are host-controlled. An agent container cannot mount them. Log files are rotated by the host's logrotate system, not by the agents.

Run commands as `agents` (not root). An escaped process obtaining full host `agents` privileges could modify other sandbox workspaces and manage rootless Podman; this is not equivalent to independent Unix-account isolation.
