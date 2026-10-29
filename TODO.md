# Ghostwire Minion — Roadmap

Last updated: 2026-10-29

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

## Phase 6b — Hardening review
**Status:** COMPLETE (2026-10-29)

- [x] SOCKS5 allowlist fails closed: an empty list lets nobody in (it used to let everyone in)
- [x] SSRF checks on resolved addresses (names, redirects, CGNAT, IPv4-mapped and NAT64 forms, own public IP), not just IP literals
- [x] API key compared in constant time; required by middleware on everything but `GET /health`
- [x] `/proxy` request validation, response size limit, race-free concurrency limit, SOCKS5 timeouts and session cap
- [x] `config.json` validated at start-up; secrets kept out of logs
- [x] Registration retries until the parent answers; heartbeat loop can't die; shutdown closes SOCKS5 sessions
- [x] `/destroy` works (it used to kill itself before removing anything) and handles OpenRC
- [x] `/upgrade` runs `scripts/upgrade.sh --yes` outside the service sandbox; OpenRC handled
- [x] `install.sh`: interactive `curl | bash` works, config written safely, steps checked, systemd unit sandboxed
- [x] pytest tests for the security-relevant code, run in CI on Python 3.10 and 3.15

---

## Phase 7 — Host watch mode
**Status:** PLANNED (added 2026-10-28, after the AKG Tech incident)

A compromised Next.js container ran an XMRig miner, a backdoor root user, cron persistence and a worm for five months on a host with nothing watching inside it. The minion is already installed on servers and reporting heartbeats, so a read-only watch mode would have caught every stage. Report: `Desktop\AKGTech-Security-Incident-Report-2026-10-28.html`.

- [ ] Optional `watch` mode (off by default, `--watch` in `install.sh`), reporting to the parent with each heartbeat or on a 5-minute timer. Read-only: it never changes the host.
- [ ] **Docker**: per-container CPU and memory (`docker stats`), image, creation time and age, published ports (flag `0.0.0.0`), privileged/root user, and mounts of the Docker socket or host paths. Needs read access to `/var/run/docker.sock`; document the risk.
- [ ] **Processes** (host and each container through `docker top`): flag executables running from `/tmp`, `/var/tmp` or `/dev/shm`; known miner names and arguments (`xmrig`, `-o host:port -u … -p …`, `stratum+tcp`); unexpected children of web runtimes (anything except `node` under `next-server`).
- [ ] **Persistence**: hash `/etc/passwd` (flag new UID-0 users), crontabs, `/etc/sudoers.d`, systemd units, and `authorized_keys`, on the host and in containers. Report changes.
- [ ] **Network**: outbound connections (`ss -tnp` / `/proc/net/tcp`) to mining ports (3333, 4444, 5555, 7777, 10001–10100, 14444) and to indicator IPs pushed from the parent.
- [ ] **Files**: SHA-256 of new executables in temp folders, checked against the parent's indicator hashes.
- [ ] Rate-limit and summarise reports, so a noisy host doesn't flood the parent.
- [ ] Docker deployment option (already listed below) with read-only socket access, for Docker Desktop and NAS hosts.

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
| Signed parent commands | `/destroy`, `/upgrade` and `/proxy` are authorised by the API key alone, sent in plaintext |
| Non-root service user | Runs as root (sandboxed) because `/upgrade` and `/destroy` use `systemd-run` |
| OpenRC supervision | OpenRC doesn't restart the minion if it crashes (`supervise-daemon` would) |
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
| No TLS on proxy | HTTP API and SOCKS5 are unencrypted, so the API key can be sniffed between parent and minion |
| Health is public | `GET /health` shows the version and the SOCKS5 allowlist (the parent's IPs) without the key; the parent reads it unauthenticated |
