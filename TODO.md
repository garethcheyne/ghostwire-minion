# Ghostwire Minion — Roadmap

Last updated: 2026-04-05

---

## Phase 1 — Core Agent
**Status:** COMPLETE

- [x] Single-file Python agent (`minion.py`)
- [x] Config file loading (`config.json`)
- [x] VERSION file for release tracking (`yyyy.mm.dd.HHMM` format)
- [x] Parent server registration (hostname, public IP, OS, arch, Python version)
- [x] Heartbeat loop with configurable interval
- [x] Graceful shutdown on SIGINT/SIGTERM
- [x] Disconnect notification to parent on shutdown
- [x] Public IP detection (ipify, ifconfig.me, ipinfo.io fallback chain)
- [x] GeoIP lookup (country, city, ISP via ipinfo.io)
- [x] Registration retry (5 attempts with increasing backoff)

## Phase 2 — HTTP Proxy
**Status:** COMPLETE

- [x] `/proxy` endpoint — relay HTTP requests through minion's IP
- [x] API key authentication (`X-Minion-API-Key` header)
- [x] Configurable SSL verification (`verify_ssl` option, default True)
- [x] Configurable redirect following (`follow_redirects` per request)
- [x] Configurable timeout per request (default 30s)
- [x] Brotli encoding stripping (aiohttp compatibility)
- [x] Request/response logging (method, URL, status, elapsed, bytes)
- [x] Latency tracking with rolling average (last 100 samples)
- [x] Bytes transferred counter
- [x] `/health` endpoint with stats (version, request count, active requests, SOCKS info)

## Phase 3 — SOCKS5 Proxy
**Status:** COMPLETE

- [x] RFC 1928 SOCKS5 server (no-auth, CONNECT only)
- [x] IPv4, IPv6, and domain name address types supported
- [x] SOCKS5 runs on `proxy_port + 1` automatically
- [x] IP allowlist for SOCKS5 connections (parent server only)
- [x] Auto-allowlist parent IP from authenticated API requests
- [x] Server IP allowlist from registration and heartbeat responses
- [x] Bidirectional data relay with byte tracking (64KB buffer)
- [x] Private network blocking on SOCKS5 CONNECT targets

## Phase 4 — Security
**Status:** COMPLETE

- [x] SSRF protection on proxy and SOCKS5 targets (RFC 1918, loopback, link-local)
- [x] IPv6 private network blocking (fc00::/7, fe80::/10)
- [x] Rate limiting (50 max concurrent requests, 429 response)
- [x] Machine ID for rogue minion detection (SHA256 of `/etc/machine-id`)
- [x] Memory leak fix (`_latencies` capped at 1000, pruned to 500)
- [x] Proper HTTP error codes (401 unauthorized, 400 bad request, 403 blocked, 429 rate limit, 502 error, 504 timeout)

## Phase 5 — Lifecycle Management
**Status:** COMPLETE

- [x] `/upgrade` endpoint — pull latest from Git, reinstall deps, restart
- [x] Auto-upgrade via heartbeat response (`upgrade_requested` flag)
- [x] Version comparison on heartbeat (`latest_agent_version`)
- [x] Upgrade preserves `config.json`
- [x] Upgrade rebuilds venv for clean dependency state
- [x] Upgrade flushes `__pycache__` and `.pyc` files
- [x] `/destroy` endpoint — self-destruct (stop service, remove files, uninstall)
- [x] Responds before performing upgrade/destroy (non-blocking)

## Phase 6 — Installer
**Status:** COMPLETE

- [x] `install.sh` — one-line curl installer from GitHub
- [x] Non-interactive mode (`--parent`, `--key`, `--port` flags)
- [x] Interactive mode with prompts and confirmation
- [x] Multi-distro support (Alpine/OpenRC, Debian/Ubuntu/RHEL/Fedora/CentOS/Arch systemd)
- [x] Auto-detect package manager (apk, apt, dnf, yum, pacman)
- [x] Auto-detect init system (systemd, OpenRC)
- [x] Python >= 3.10 check with auto-install
- [x] Python venv creation with pip bootstrap fallback
- [x] Deadsnakes PPA fallback for Ubuntu when python3-venv is missing
- [x] systemd service unit (hardened: NoNewPrivileges, ProtectSystem, PrivateTmp)
- [x] OpenRC service script for Alpine
- [x] Firewall auto-configuration (UFW, firewalld, iptables)
- [x] In-place upgrade detection (existing install preserves config)
- [x] Post-install verification (service status, health check, SOCKS5 port check)
- [x] Version display from local file, installed copy, or GitHub fetch

---

## Future Work

| Feature | Notes |
|---------|-------|
| Multi-parent support | Register with multiple Ghostwire instances |
| Load balancing participation | Accept routing weight from parent |
| Geographic routing | Country/city tracked but not used for routing decisions |
| Bandwidth throttling | `bytes_transferred` tracked but not enforced |
| TLS on proxy/SOCKS5 ports | Currently plaintext; relies on network trust or SSH tunnel |
| SOCKS5 authentication | Currently relies on IP allowlist only |
| Alpine OpenRC destroy/upgrade | `_self_destruct` and `_self_upgrade` use systemctl only |
| Config hot-reload | Currently requires restart for config changes |
| Prometheus metrics endpoint | Expose `/metrics` for monitoring |
| Docker deployment option | Alternative to bare-metal install |
| Windows/macOS support | Currently Linux-only |
| WebSocket tunnel mode | For networks that block non-HTTP traffic |
| Automatic log rotation | For OpenRC deployments (systemd uses journald) |
| Connection pooling | For high-throughput proxy workloads |

---

## Known Limitations

| Issue | Description |
|-------|-------------|
| Linux only | Installer requires systemd or OpenRC; no Windows/macOS support |
| Root required | Install script must run as root for service management |
| Single parent | Each minion can only register with one Ghostwire instance |
| No SOCKS5 auth | SOCKS5 access is restricted by IP allowlist, not credentials |
| No TLS on proxy | HTTP API and SOCKS5 are unencrypted |
| Self-destruct is systemd-only | `_self_destruct()` uses systemd commands; OpenRC not handled |
| Upgrade is systemd-only | `_self_upgrade()` restarts via systemctl; OpenRC not handled |
