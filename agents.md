<!-- File: agents.md -->

# Agent Context: GlobalProtect Proxy

## Project Overview

This project encapsulates a GlobalProtect VPN client inside a Docker container, exposing it via a SOCKS5 proxy (`microsocks`) on port 1080. It uses a custom Python-based web UI on port 8001 to handle the authentication flow.

## Development Standards (Crucial)

**Strict linting and formatting are enforced via CI and Pre-commit hooks.** Any code changes must adhere to these standards to pass the `lint` workflow.

- **Python:** Uses `ruff` for formatting (line length 120) and linting. **Strict typing is required.** The project uses Python 3.14.
- **Shell:** Uses `shellcheck` (gcc format).
- **Formatting:** Uses `prettier` for Markdown, YAML, HTML, and JSON.
- **YAML:** Uses `yamllint` (relaxed mode, max 120 chars).
- **Docker:** Uses `hadolint` (ignores DL3008).

## Architecture

The system uses a "Split Brain" architecture for stability:

1.  **The Brain (Python - `server.py`):**
    - Runs the Web UI (Port 8001).
    - Parses logs (`vpn.log`) to determine state (Idle, Connecting, Auth, Input, Connected, Error).
    - **API:** Provides endpoints for status, connection control, input submission, and log downloading.
2.  **The Muscle (Bash - `entrypoint.sh`):**
    - Sets up networking based on `VPN_MODE`.
    - **Watchdogs:**
        - **Service Watchdog:** Restarts container if `server.py` or `gpservice` dies.
        - **DNS Watchdog:** Monitors `/etc/resolv.conf` for VPN-pushed DNS changes and dynamically updates `iptables` NAT rules to ensure traffic forwarding works.
        - **Log Watchdog:** Truncates log files if they exceed 10MB to prevent disk exhaustion.
    - Manages the `gpclient` process.

### Privilege Separation Strategy

The container operates primarily as the non-root user `gpuser` to secure the web interface and log files.

- **`gpuser`:** Runs `server.py`, `microsocks`, and `gpservice`.
- **`gpservice`:** Granted `cap_net_admin` and `cap_net_bind_service` capabilities to manage network interfaces without running as full root.
- **`sudo gpclient`:** The connection client runs as `root` (invoked via passwordless `sudo` by `gpuser`) to perform `TUNSETIFF` operations on the kernel.
    - **Restriction:** `gpuser` is strictly limited in `/etc/sudoers` to only execute `/usr/bin/gpclient` and `/usr/bin/pkill`.

### Health Checks

The Dockerfile includes a `HEALTHCHECK` that queries the internal status endpoint:
`CMD python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8001/status.json').getcode())" || exit 1`

## Environment Variables

| Variable        | Default      | Description                                                                    |
| :-------------- | :----------- | :----------------------------------------------------------------------------- |
| `VPN_PORTAL`    | **Required** | The URL of your GlobalProtect portal.                                          |
| `VPN_MODE`      | `standard`   | `standard` (SOCKS + NAT), `socks` (SOCKS only), `gateway` (NAT only).          |
| `LOG_LEVEL`     | `INFO`       | `TRACE` (Granular), `DEBUG` (Process flow + UI Log Download), `INFO`.          |
| `GP_ARGS`       | `(Empty)`    | Additional arguments passed directly to `gpclient` (e.g., `--user-agent "X"`). |
| `DNS_SERVERS`   | `(Empty)`    | Comma-separated IPs (e.g., `1.1.1.1`). Forces update of `/etc/resolv.conf`.    |
| `TZ`            | `UTC`        | Timezone for logs and system time.                                             |
| `PUID` / `PGID` | `(Unset)`    | User/Group ID override for file permission compatibility.                      |

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
- **Debug:** Set `LOG_LEVEL=TRACE` to see exactly which lines the regex parser is scanning.
- **Logs:** If `LOG_LEVEL` is `DEBUG` or higher, a "Download Logs" link appears in the Web UI footer.

## Future Improvements

- **Automated Callback:** Requires an embedded browser extension or custom handler to POST the callback to `localhost:8001/submit` automatically.
