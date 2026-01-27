# Agent Context: GlobalProtect Proxy

## Project Overview

This project encapsulates a GlobalProtect VPN client inside a Docker container, exposing it via a SOCKS5 proxy (`microsocks`) on port 1080. It uses a custom Python-based web UI on port 8001 to handle the authentication flow.

## Architecture

The system uses a "Split Brain" architecture for stability:

1.  **The Brain (Python - `server.py`):**
    - Runs the Web UI.
    - Parses logs (`vpn.log`) to determine state.
    - **Logging:** Uses structured python logging. controlled by `LOG_LEVEL`.
2.  **The Muscle (Bash - `entrypoint.sh`):**
    - Sets up networking based on `VPN_MODE`.
    - Manages `gpclient` process.
    - **Logging:** Uses custom log function mapping to `LOG_LEVEL`.

### Privilege Separation Strategy

The container operates primarily as the non-root user `gpuser` to secure the web interface and log files. However, VPN tunnel creation requires root privileges.

- **`gpuser`:** Runs the Python web server, `microsocks`, and the `gpservice` background daemon.
- **`sudo gpclient`:** The connection client runs as `root` (invoked via passwordless `sudo` by `gpuser`) to allow manipulation of the kernel network stack (specifically `TUNSETIFF` operations).

## Environment Variables

| Variable      | Default      | Description                                                                                                              |
| :------------ | :----------- | :----------------------------------------------------------------------------------------------------------------------- |
| `VPN_PORTAL`  | **Required** | The URL of your GlobalProtect portal.                                                                                    |
| `LOG_LEVEL`   | `INFO`       | Controls verbosity. Options: `TRACE` (Granular), `DEBUG` (Process flow), `INFO` (State changes).                         |
| `VPN_MODE`    | `standard`   | Controls functionality. Options: `standard`, `socks`, `gateway`.                                                         |
| `DNS_SERVERS` | `(Empty)`    | **Overrides DNS settings.** Provide comma-separated IPs (e.g., `10.0.0.5,1.1.1.1`). Forces update of `/etc/resolv.conf`. |

### DNS Behavior

- **Custom (`DNS_SERVERS` set):** Always overwrites `/etc/resolv.conf` with provided values. Use this if Docker DNS is failing or if you need internal DNS resolution over the VPN.
- **Macvlan Auto-Fix:** If `DNS_SERVERS` is empty but `macvlan` is detected, defaults to `8.8.8.8, 1.1.1.1` to bypass common Docker isolation issues.
- **Default:** Uses system/Docker DNS settings.

### Operational Modes (`VPN_MODE`)

- **`standard`:** Starts `microsocks` (port 1080) AND configures `iptables` for NAT/IP Forwarding. Best for general use.
- **`socks`:** Starts `microsocks` ONLY. Disables IP Forwarding and NAT. Use this if you only need the SOCKS5 proxy and want to lock down the container.
- **`gateway`:** Configures NAT/IP Forwarding ONLY. Does not start `microsocks`. Use this if using the container strictly as a gateway for other devices (via macvlan).

## Key Files

- **`entrypoint.sh`:** Handles `VPN_MODE` logic, DNS configuration, and network setup. Invokes `gpclient` using `sudo`.
- **`server.py`:** Handles `LOG_LEVEL` parsing and log analysis.
- **`debug_parser.log`:** The primary debug artifact. Both Bash and Python write here.

## Handling Callbacks (`globalprotect://`)

The SAML flow often ends with a redirect to `globalprotect://...`.

- **Handling:** `server.py` accepts the raw URL via `/submit` and passes it to `gpclient`.
- **Debug:** Set `LOG_LEVEL=TRACE` to see exactly which lines the regex parser is scanning and rejecting.

## Future Improvements

- **Automated Callback:** Requires a browser extension or custom protocol handler on the _host_ machine to POST the callback to `localhost:8001/submit`.
