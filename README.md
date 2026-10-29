# Ghostwire Minion

A lightweight proxy agent that connects to a Ghostwire parent server and relays the parent's requests
through this machine's IP address: HTTP requests through its HTTP API, and TCP connections through a
SOCKS5 proxy on the next port up. It's a single Python file (`minion.py`) that runs as a system service
on the distro's own Python, 3.10 or later.

## Quick Install

**Interactive** — you'll be prompted for parent URL and API key:

```bash
curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh | sudo bash
```

**Non-interactive** — pass everything on the command line (ideal for scripting/automation):

```bash
curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh \
  | sudo bash -s -- --parent https://ghostwire.err403.com --key gw-node-YOUR_KEY
```

Or clone and run manually:

```bash
git clone https://github.com/garethcheyne/ghostwire-minion.git
cd ghostwire-minion
sudo ./install.sh --parent https://ghostwire.err403.com --key gw-node-YOUR_KEY --port 1080
```

### Install options

| Flag | Description |
|------|-------------|
| `--parent`, `-p` | Ghostwire server URL |
| `--key`, `-k` | Minion API key (starts with `gw-node-`) |
| `--port` | HTTP API port (default: `1080`); SOCKS5 listens on the next port up |

If `--parent` and `--key` are both provided, the installer runs fully non-interactive. Otherwise it
asks on the terminal (also when piped from curl). Use an `https://` parent URL: with `http://` the API
key crosses the network unencrypted, and the installer and the minion both warn about it.

Running the installer again on a machine that has the minion upgrades the code and keeps `config.json`.

## Configuration

The installer writes `/opt/ghostwire-minion/config.json` (mode 600, it holds the API key). The minion
checks it at start-up and refuses to start, with a message saying what's wrong, if it's invalid.

| Key | Default | Meaning |
|-----|---------|---------|
| `server_url` | (required) | The parent's URL, `https://` recommended |
| `api_key` | (required) | The minion's key (`gw-node-…`), sent to the parent as `X-Worker-API-Key` and expected from it as `X-Minion-API-Key` |
| `proxy_port` | `1080` | HTTP API port |
| `socks_port` | `proxy_port + 1` | SOCKS5 port (the parent assumes `proxy_port + 1`, so change it only if you know why) |
| `verify_ssl` | `true` | Check TLS certificates of proxied targets. The parent's certificate is always checked |
| `max_response_bytes` | `52428800` (50 MB) | Largest target response relayed back; bigger ones get a 502 |

Restart the service after changing it.

## Security

The minion is a proxy on the internet, so it's locked down to its parent:

- **HTTP API.** `POST /proxy`, `POST /upgrade` and `POST /destroy` need the `X-Minion-API-Key` header
  (compared in constant time); everything except `GET /health` answers 401 without it.
- **SOCKS5** takes connections only from IPs on its allowlist, which the parent manages: the parent's
  `server_ips` from registration and every heartbeat, plus the source IP of each request that
  authenticated with the API key. **An empty allowlist lets nobody in.** SOCKS5 itself has no
  authentication (`no-auth`, CONNECT only).
- **No internal targets.** Both proxies refuse anything that isn't a public address: private,
  loopback, link-local (cloud metadata such as `169.254.169.254`), CGNAT, multicast and reserved ranges,
  IPv4-mapped and NAT64 forms of those, and this machine's own public IP. Names are checked when
  they're resolved and the connection goes to the checked address, and each redirect hop is checked.
- **Limits.** 50 concurrent `/proxy` requests (then 429), timeouts of at most 300 s, 1 MB request
  bodies, `max_response_bytes` responses, 512 SOCKS5 sessions, and timeouts on the SOCKS5 handshake.
- **Service sandbox.** Under systemd it runs with `ProtectSystem=strict` (only its own folder
  writable), `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, no capabilities beyond
  binding a port, and the kernel protections (`systemd-analyze security ghostwire-minion` rates it
  3.5, OK). `/upgrade` and `/destroy` run their work outside the sandbox through `systemd-run`.
- **Logs** never include the API key, and proxied URLs are logged without their query strings.

Traffic between the parent and the minion's HTTP API and SOCKS5 port isn't encrypted (see TODO.md),
so the parent should reach the minion over a network you trust or a tunnel.

## Upgrading

Every Ghostwire app has the same `scripts/upgrade.sh`, with the same options and steps. The installer
puts the minion's in `/opt/ghostwire-minion/scripts/`; run it on the minion as root:

```bash
sudo /opt/ghostwire-minion/scripts/upgrade.sh             # upgrade to the latest version (asks first)
sudo /opt/ghostwire-minion/scripts/upgrade.sh --check     # say what an upgrade would do; changes nothing
sudo /opt/ghostwire-minion/scripts/upgrade.sh --rollback  # go back to what ran before the last upgrade
sudo /opt/ghostwire-minion/scripts/upgrade.sh --yes       # don't ask (cron); add a tag to go to that version
```

It downloads the new version, backs up `config.json` and the code, keeps the running code in
`.previous` for `--rollback`, runs the new `install.sh` (which keeps your config), then checks that
the service is running and the HTTP and SOCKS5 ports answer. Backups and a log of each run are kept
in `/opt/ghostwire-minion/backups/`. A minion installed before the script existed gets it by running
the install command once more.

## Supported Distros

| Distro | Package Manager | Init System |
|--------|----------------|-------------|
| Alpine | apk | OpenRC |
| Debian / Ubuntu | apt | systemd |
| RHEL / Fedora / CentOS | dnf / yum | systemd |
| Arch | pacman | systemd |

The installer auto-detects your package manager and init system.

## Setup

During interactive installation you'll be asked two questions:

1. **Who is your parent?** — Your Ghostwire server URL (e.g. `https://ghostwire.err403.com`)
2. **API Key** — The minion API key from your Ghostwire dashboard (Worker Nodes page)

That's it. The minion registers itself, starts proxying, and reports back to the parent.

## How It Works

```
┌─────────────┐         ┌─────────────────┐         ┌──────────┐
│  Ghostwire  │──req──▶ │  Minion (proxy)  │──req──▶ │  Target  │
│   (parent)  │◀──res── │  IP: 203.0.1.5   │◀──res── │  Server  │
└─────────────┘         └─────────────────┘         └──────────┘
```

1. On start-up the minion registers with the parent (`/api/worker-nodes/agent/register`), retrying
   with backoff until the parent answers
2. Ghostwire sends a request to the minion's `/proxy` endpoint, or connects through its SOCKS5 port
3. The minion makes the actual request from its own IP
4. The response is relayed back to Ghostwire
5. The minion sends periodic heartbeats (`/api/worker-nodes/agent/heartbeat`) to report its status
   and pick up allowlist changes and upgrade requests, and tells the parent when it stops

### HTTP API

| Endpoint | Key | Does |
|----------|-----|------|
| `GET /health` | no | Version, request counts, the SOCKS5 port and allowlist |
| `POST /proxy` | yes | Makes the request in the JSON body (`url`, `method`, `headers`, `body`, `timeout`, `follow_redirects`) and returns `status_code`, `headers`, `body`, `elapsed_ms`, `worker_ip`. 400 for a bad request, 403 for an internal target, 429 when busy, 502 when the target fails, 504 on timeout |
| `POST /upgrade` | yes | Runs `scripts/upgrade.sh --yes`, which upgrades to the latest release and restarts the service |
| `POST /destroy` | yes | Stops the service and removes it and `/opt/ghostwire-minion` |

## Commands

### systemd (Debian, Ubuntu, RHEL, Fedora, Arch)

```bash
sudo systemctl status ghostwire-minion
sudo journalctl -u ghostwire-minion -f
sudo systemctl restart ghostwire-minion
```

### OpenRC (Alpine)

```bash
sudo rc-service ghostwire-minion status
sudo tail -f /var/log/ghostwire-minion.log
sudo rc-service ghostwire-minion restart
```

### Health check (all distros)

```bash
curl http://localhost:1080/health
```

## Uninstall

Deleting the minion from the Worker Nodes page in Ghostwire sends it `/destroy`, which removes it
(systemd and OpenRC). The installer's firewall rules for the two ports stay. To remove it by hand:

### systemd

```bash
sudo systemctl stop ghostwire-minion
sudo systemctl disable ghostwire-minion
sudo rm /etc/systemd/system/ghostwire-minion.service
sudo systemctl daemon-reload
sudo rm -rf /opt/ghostwire-minion
```

### OpenRC (Alpine)

```bash
sudo rc-service ghostwire-minion stop
sudo rc-update del ghostwire-minion default
sudo rm /etc/init.d/ghostwire-minion
sudo rm -rf /opt/ghostwire-minion
```

## Development

`minion.py` must stay compatible with Python 3.10 (hosts run it on their distro's Python), even though
CI and the lint rules target 3.15. Lint, format and tests are the same as CI:

```bash
pip install -r requirements-dev.txt ruff==0.17.3
ruff check . && ruff format --check .
python -m pytest
```

The tests (`tests/`) cover the security-relevant code: the API key, the SOCKS5 allowlist, internal
target checks, request validation and config loading. CI runs them on Python 3.10 and 3.15.

## License

MIT
