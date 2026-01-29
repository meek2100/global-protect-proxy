<!-- File: agents.md -->

# Agent Context: GlobalProtect Proxy

## Project Overview

This project encapsulates a GlobalProtect VPN client inside a Docker container, exposing it via a SOCKS5 proxy (`microsocks`) on port 1080. It uses a custom Python-based web UI on port 8001 to handle the authentication flow.

## Development Standards (Crucial)

**Strict linting and formatting are enforced via CI and Pre-commit hooks.** Any code changes must adhere to these standards to pass the `lint` workflow.

- **Python:** Uses `ruff` for formatting (line length 120) and linting. **Strict typing (Mypy/Pyright) is required.** The project uses Python 3.14.
- **Shell:** Uses `shellcheck` (gcc format).
- **Formatting:** Uses `prettier` for Markdown, YAML, HTML, and JSON.
- **YAML:** Uses `yamllint` (relaxed mode, max 120 chars).
- **Docker:** Uses `hadolint` (ignores DL3008).

## Architecture

The system uses an **"On-Demand" Split Brain architecture** to minimize resource usage and ensure stability:

1.  **The Brain (Python - `server.py`):**
    - Runs the Web UI (Port 8001).
    - Parses logs (`vpn.log`) to determine state (Idle, Connecting, Auth, Input, Connected, Error).

- **API:** Endpoints for `/status.json` (polled), `/connect`, and `/disconnect`.
- **Optimization:** `/status.json` logs at `DEBUG` level to prevent production log flooding. All other actions log at `INFO`.
- **Role:** It is the _only_ service guaranteed to be running 24/7.

1.  **The Muscle (Bash - `entrypoint.sh`):**
    - **Startup:** Normalizes environment variables (case-insensitive, trims quotes).
    - **On-Demand Execution:** `gpservice` and `gpclient` are **NOT** started at boot. They are only launched when the User clicks "Connect" (via named pipe signal).
    - **Cleanup:** When the VPN disconnects, `gpservice` is explicitly killed to prevent zombie processes or "stuck" states.

### Watchdogs & Self-Healing

- **Service Watchdog:**
    - Checks `server.py` continuously.
    - Checks `gpservice` **ONLY** if the VPN is in `active` mode. If `gpservice` dies while active, it logs a critical error.
    - Ignores `gpservice` when in `idle` mode (expected behavior).
- **DNS Watchdog:** Monitors `/etc/resolv.conf` for VPN-pushed DNS changes and dynamically updates `iptables` NAT rules to ensure traffic forwarding works.
- **Log Watchdog:** Truncates log files (`gp-service.log`, `gp-client.log`) if they exceed 10MB.

## Configuration & Environment

The `entrypoint.sh` includes a robust parser that handles case sensitivity and quoting issues (e.g., `log_level=debug` becomes `LOG_LEVEL=DEBUG`).

| Variable        | Default      | Description                                                                      |
| :-------------- | :----------- | :------------------------------------------------------------------------------- |
| `VPN_PORTAL`    | **Required** | The URL of your GlobalProtect portal.                                            |
| `VPN_MODE`      | `standard`   | `standard` (SOCKS + NAT), `socks` (SOCKS only), `gateway` (NAT only).            |
| `LOG_LEVEL`     | `INFO`       | `TRACE` (-vv), `DEBUG` (-v + status logs), `INFO` (Quiet).                       |
| `GP_ARGS`       | `(Empty)`    | Additional arguments passed directly to `gpclient`.                              |
| `DNS_SERVERS`   | `(Empty)`    | Comma/Space separated IPs (e.g., `1.1.1.1, 8.8.8.8`). Forces `/etc/resolv.conf`. |
| `TZ`            | `UTC`        | Timezone for logs and system time.                                               |
| `PUID` / `PGID` | `(Unset)`    | User/Group ID override for file permission compatibility.                        |

### Privilege Separation Strategy

The container operates primarily as the non-root user `gpuser`.

- **`gpuser`:** Runs `server.py`, `microsocks`, and `gpservice`.
- **`sudo` Scope:** `gpuser` is strictly limited in `/etc/sudoers` to only execute:
    - `/usr/bin/gpclient`: Required for TUN interface management.
    - `/usr/bin/pkill`: Required for service cleanup.
    - `/usr/bin/gpservice`: (Implicitly managed via user permissions, no sudo needed for execution, only kill).

### Operational Modes (`VPN_MODE`)

- **`standard`:** Starts `microsocks` (port 1080) AND configures `iptables` for NAT/IP Forwarding. Best for general use.
- **`socks`:** Starts `microsocks` ONLY. Disables IP Forwarding and NAT. Locked down.
- **`gateway`:** Configures NAT/IP Forwarding ONLY. No SOCKS proxy. Requires `macvlan` network driver.

## Key Files

- **`entrypoint.sh`:** Orchestrator. Handles `VPN_MODE`, DNS Watchdog, cleanup traps, and invokes `gpclient`.
- **`server.py`:** Web Server. Handles `LOG_LEVEL` parsing, log analysis regex, and ANSI stripping.
- **`index.html`:** Frontend. Supports **Dark Mode** (auto/toggle), dynamic form generation (dropdowns/password), and state visualization.
- **`debug_parser.log`:** The primary debug artifact. Both Bash and Python write here.

## Handling Callbacks (`globalprotect://`)

The SAML flow often ends with a redirect to `globalprotect://...`.

- **Handling:** `server.py` accepts the raw URL via `/submit` and passes it to `gpclient` via a named pipe (`/tmp/gp-stdin`).
- **Debugging:** Set `LOG_LEVEL=DEBUG` to enable the "Download Logs" button in the Web UI.
- **Logs:** If `LOG_LEVEL` is `DEBUG` or higher, a "Download Logs" link appears in the Web UI footer.

## Future Improvements

- **Frontend:** Ensure `index.html` has **zero external dependencies** (inline CSS/JS) for strict LAN-only deployments.
- **Automated Callback:** Requires an embedded browser extension or custom handler to POST the callback to `localhost:8001/submit` automatically.
