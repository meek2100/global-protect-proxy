# Agent Context: GlobalProtect Proxy

## Project Overview

This project encapsulates a GlobalProtect VPN client inside a Docker container, exposing it via a SOCKS5 proxy (`microsocks`) on port 1080. It uses a custom Python-based web UI on port 8001 to handle the authentication flow, specifically designed for SAML/SSO environments where a GUI is not available.

## Architecture

The system uses a "Split Brain" architecture for stability:

1.  **The Brain (Python - `server.py`):**
    - Runs the Web UI.
    - Parses logs (`vpn.log`) to determine state (`idle`, `auth`, `connected`).
    - Receives user input (callbacks).
    - Writes commands to Named Pipes.
2.  **The Muscle (Bash - `entrypoint.sh`):**
    - Sets up networking (iptables, DNS).
    - Manages the `gpclient` process lifecycle.
    - Reads from Named Pipes to start/stop the VPN.

## Key Files

- **`entrypoint.sh`:** The container entrypoint. Handles root-level network setup, creates pipes (`/tmp/gp-control`, `/tmp/gp-stdin`), and loops waiting for start signals.
- **`server.py`:** Runs as `gpuser`. Serves `index.html` and `status.json`. It is the source of truth for the application state.
- **`index.html`:** The frontend. Polls `/status.json`.
- **`vpn.log`:** The shared memory. `gpclient` writes here; `server.py` reads here.

## State Management (Important)

- **Idle:** `entrypoint.sh` has not started `gpclient`. `/tmp/gp-mode` contains "idle".
- **Connecting:** `entrypoint.sh` is running `gpclient`. `/tmp/gp-mode` contains "active".
- **Auth:** `server.py` detected a SAML URL in `vpn.log`.
- **Connected:** `server.py` detected "Connected" in `vpn.log`.

## Handling Callbacks (`globalprotect://`)

The SAML flow often ends with a redirect to `globalprotect://...`.

- **Problem:** The browser cannot open this link (no app installed).
- **Solution:** The user must copy this URL manually.
- **Handling:** `server.py` accepts the raw `globalprotect://` URL via the `/submit` endpoint and passes it to the `gpclient` stdin pipe. The client binary handles the parsing.

## Future Improvements

- **Automated Callback:** Requires a browser extension or custom protocol handler on the _host_ machine to POST the callback to `localhost:8001/submit`.
