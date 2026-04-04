#!/usr/bin/env python3
"""
Ghostwire Minion — Lightweight proxy agent

Registers with a Ghostwire parent server and relays HTTP requests
through this machine's IP address. That's it.

Usage:
    python minion.py          (reads config.json in same directory)
"""
from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import logging
import os
import platform
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import aiohttp
from aiohttp import web

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_FILE = Path(__file__).parent / "config.json"
VERSION = "2026.04.05.1400"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("ghostwire-minion")


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        log.error("config.json not found — run install.sh first")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Security helpers
# ---------------------------------------------------------------------------

_BLOCKED_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"}
_BLOCKED_NETWORKS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
]


def _is_blocked_url(url: str) -> bool:
    """Block requests to internal/private networks"""
    try:
        parsed = urlparse(url)
        hostname = parsed.hostname
        if not hostname:
            return True
        if hostname.lower() in _BLOCKED_HOSTS:
            return True
        try:
            ip = ipaddress.ip_address(hostname)
            for net in _BLOCKED_NETWORKS:
                if ip in net:
                    return True
        except ValueError:
            pass  # Domain name, not IP
    except Exception:
        return True
    return False


def _get_machine_id() -> str:
    """Get a stable machine identifier"""
    try:
        # Try reading machine-id (Linux)
        for path in ["/etc/machine-id", "/var/lib/dbus/machine-id"]:
            try:
                with open(path) as f:
                    return hashlib.sha256(f.read().strip().encode()).hexdigest()[:32]
            except FileNotFoundError:
                continue
        # Fallback: hostname + platform
        return hashlib.sha256(f"{socket.gethostname()}-{platform.machine()}".encode()).hexdigest()[:32]
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# IP + Geo helpers
# ---------------------------------------------------------------------------

async def get_public_ip() -> str | None:
    urls = [
        "https://api.ipify.org?format=json",
        "https://ifconfig.me/all.json",
        "https://ipinfo.io/json",
    ]
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as s:
        for url in urls:
            try:
                async with s.get(url) as r:
                    if r.status == 200:
                        d = await r.json(content_type=None)
                        return d.get("ip") or d.get("query")
            except Exception:
                continue
    return None


async def get_ip_geo(ip: str) -> dict:
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as s:
            async with s.get(f"https://ipinfo.io/{ip}/json") as r:
                if r.status == 200:
                    d = await r.json(content_type=None)
                    return {
                        "country": d.get("country", ""),
                        "city": f"{d.get('city', '')}, {d.get('region', '')}".strip(", "),
                        "isp": d.get("org", ""),
                    }
    except Exception:
        pass
    return {"country": None, "city": None, "isp": None}


# ---------------------------------------------------------------------------
# Proxy handler — the only real job of a minion
# ---------------------------------------------------------------------------

class ProxyHandler:
    def __init__(self, api_key: str, verify_ssl: bool = True):
        self.api_key = api_key
        self.verify_ssl = verify_ssl
        self.request_count = 0
        self.bytes_transferred = 0
        self.active_requests = 0
        self.max_concurrent = 50
        self._latencies: list[float] = []
        self._public_ip: str | None = None
        self.socks_port: int = 0

    @property
    def avg_latency_ms(self) -> float | None:
        if not self._latencies:
            return None
        recent = self._latencies[-100:]
        return sum(recent) / len(recent)

    async def handle_proxy(self, request: web.Request) -> web.Response:
        """Relay a request from the Ghostwire parent through this IP."""
        if request.headers.get("X-Minion-API-Key", "") != self.api_key:
            return web.json_response({"error": "Unauthorized"}, status=401)

        if self.active_requests >= self.max_concurrent:
            return web.json_response({"error": "Rate limit exceeded — too many concurrent requests"}, status=429)

        try:
            body = await request.json()
        except Exception:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        url = body.get("url")
        method = body.get("method", "GET").upper()
        headers = body.get("headers") or {}
        req_body = body.get("body")
        timeout = body.get("timeout", 30)
        follow = body.get("follow_redirects", True)

        if not url:
            return web.json_response({"error": "url is required"}, status=400)

        if _is_blocked_url(url):
            return web.json_response({"error": "Target URL is blocked (internal/private network)"}, status=403)

        self.active_requests += 1
        t0 = time.monotonic()

        try:
            ct = aiohttp.ClientTimeout(total=timeout)
            async with aiohttp.ClientSession(timeout=ct) as session:
                async with session.request(
                    method, url,
                    headers=headers,
                    data=req_body,
                    allow_redirects=follow,
                    ssl=None if self.verify_ssl else False,
                ) as resp:
                    resp_body = await resp.text()
                    resp_headers = dict(resp.headers)
                    elapsed = (time.monotonic() - t0) * 1000

                    self.request_count += 1
                    self.bytes_transferred += len(resp_body.encode())
                    self._latencies.append(elapsed)
                    if len(self._latencies) > 1000:
                        self._latencies = self._latencies[-500:]

                    log.info("PROXY %s %s → %d (%.0fms, %d bytes)", method, url[:100], resp.status, elapsed, len(resp_body.encode()))

                    return web.json_response({
                        "status_code": resp.status,
                        "headers": resp_headers,
                        "body": resp_body,
                        "elapsed_ms": round(elapsed, 2),
                        "worker_ip": self._public_ip or "unknown",
                    })
        except asyncio.TimeoutError:
            log.warning("PROXY %s %s → TIMEOUT (%.0fms)", method, url[:100], (time.monotonic() - t0) * 1000)
            return web.json_response(
                {"error": "Request timed out", "elapsed_ms": round((time.monotonic() - t0) * 1000, 2)},
                status=504,
            )
        except Exception as e:
            log.error("PROXY %s %s → ERROR: %s (%.0fms)", method, url[:100], e, (time.monotonic() - t0) * 1000)
            return web.json_response(
                {"error": str(e), "elapsed_ms": round((time.monotonic() - t0) * 1000, 2)},
                status=502,
            )
        finally:
            self.active_requests -= 1

    async def handle_health(self, _request: web.Request) -> web.Response:
        return web.json_response({
            "status": "ok",
            "version": VERSION,
            "requests_proxied": self.request_count,
            "active_requests": self.active_requests,
            "socks_port": getattr(self, 'socks_port', None),
        })

    async def handle_destroy(self, request: web.Request) -> web.Response:
        """Self-destruct: stop service, remove files, uninstall"""
        if request.headers.get("X-Minion-API-Key", "") != self.api_key:
            return web.json_response({"error": "Unauthorized"}, status=401)

        log.warning("DESTROY command received — self-destructing")

        # Respond before destroying
        resp = web.json_response({"status": "destroying", "message": "Minion is removing itself"})
        await resp.prepare(request)
        await resp.write_eof()

        # Schedule destruction after response is sent
        asyncio.get_event_loop().call_later(1, lambda: asyncio.ensure_future(self._self_destruct()))
        return resp

    async def handle_upgrade(self, request: web.Request) -> web.Response:
        """Pull latest code from Git, reinstall deps, restart the service."""
        if request.headers.get("X-Minion-API-Key", "") != self.api_key:
            return web.json_response({"error": "Unauthorized"}, status=401)

        log.info("UPGRADE command received — starting upgrade")

        # Respond before upgrading (the restart will kill this process)
        resp = web.json_response({
            "status": "upgrading",
            "current_version": VERSION,
            "message": "Pulling latest code and restarting",
        })
        await resp.prepare(request)
        await resp.write_eof()

        asyncio.get_event_loop().call_later(1, lambda: asyncio.ensure_future(self._self_upgrade()))
        return resp

    async def _self_upgrade(self):
        """Pull latest code, install deps, restart service."""
        install_dir = Path(__file__).parent
        repo_url = "https://github.com/garethcheyne/ghostwire-minion.git"

        try:
            # Pull latest code into temp dir
            tmp = Path("/tmp/gw-minion-upgrade")
            if tmp.exists():
                subprocess.run(["rm", "-rf", str(tmp)], timeout=10)
            log.info("Cloning latest from %s", repo_url)
            result = subprocess.run(
                ["git", "clone", "--depth", "1", repo_url, str(tmp)],
                capture_output=True, text=True, timeout=60,
            )
            if result.returncode != 0:
                log.error("Git clone failed: %s", result.stderr)
                return

            # Copy new files (preserve config.json)
            for fname in ["minion.py", "requirements.txt", "install.sh"]:
                src = tmp / fname
                if src.exists():
                    dest = install_dir / fname
                    dest.write_bytes(src.read_bytes())
                    log.info("Updated %s", fname)

            # Reinstall deps
            venv_pip = install_dir / "venv" / "bin" / "pip"
            if venv_pip.exists():
                log.info("Installing requirements...")
                subprocess.run(
                    [str(venv_pip), "install", "--quiet", "-r", str(install_dir / "requirements.txt")],
                    timeout=120, capture_output=True,
                )

            # Cleanup
            subprocess.run(["rm", "-rf", str(tmp)], timeout=10)

            # Read new version from the freshly pulled minion.py
            new_version = "unknown"
            try:
                for line in (install_dir / "minion.py").read_text().splitlines():
                    if line.strip().startswith("VERSION"):
                        new_version = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break
            except Exception:
                pass
            log.info("Upgrade complete: %s -> %s — restarting service", VERSION, new_version)

            # Restart via systemd (or just exit and let systemd restart us)
            subprocess.run(["systemctl", "restart", "ghostwire-minion"], timeout=10, capture_output=True)

        except Exception as e:
            log.error("Upgrade failed: %s", e)
        finally:
            # If systemctl restart didn't kill us, exit so systemd respawns
            os._exit(0)

    async def _self_destruct(self):
        """Remove minion from the host OS"""
        try:
            cmds = [
                ["systemctl", "stop", "ghostwire-minion"],
                ["systemctl", "disable", "ghostwire-minion"],
                ["rm", "-f", "/etc/systemd/system/ghostwire-minion.service"],
                ["systemctl", "daemon-reload"],
                ["rm", "-rf", "/opt/ghostwire-minion"],
            ]
            for cmd in cmds:
                try:
                    subprocess.run(cmd, timeout=10, capture_output=True)
                except Exception as e:
                    log.warning("Destroy step failed: %s — %s", cmd, e)

            log.info("Self-destruct complete")
        except Exception as e:
            log.error("Self-destruct error: %s", e)
        finally:
            os._exit(0)


# ---------------------------------------------------------------------------
# SOCKS5 proxy server (RFC 1928, no-auth, CONNECT only)
# ---------------------------------------------------------------------------

class Socks5Server:
    """Minimal SOCKS5 proxy server (RFC 1928, no-auth, CONNECT only)"""

    def __init__(self, proxy: ProxyHandler):
        self.proxy = proxy
        self._server = None

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle a single SOCKS5 client connection"""
        try:
            # 1. Greeting: client sends version + methods
            header = await reader.readexactly(2)
            version, nmethods = header
            if version != 0x05:
                writer.close()
                return
            methods = await reader.readexactly(nmethods)

            # 2. Select no-auth (0x00)
            writer.write(b'\x05\x00')
            await writer.drain()

            # 3. Request: version, cmd, rsv, atyp, addr, port
            req = await reader.readexactly(4)
            ver, cmd, _, atyp = req

            if cmd != 0x01:  # Only CONNECT
                writer.write(b'\x05\x07\x00\x01' + b'\x00' * 6)
                await writer.drain()
                writer.close()
                return

            # Parse destination address
            if atyp == 0x01:  # IPv4
                addr_bytes = await reader.readexactly(4)
                host = socket.inet_ntoa(addr_bytes)
            elif atyp == 0x03:  # Domain
                length = (await reader.readexactly(1))[0]
                host = (await reader.readexactly(length)).decode()
            elif atyp == 0x04:  # IPv6
                addr_bytes = await reader.readexactly(16)
                host = socket.inet_ntop(socket.AF_INET6, addr_bytes)
            else:
                writer.write(b'\x05\x08\x00\x01' + b'\x00' * 6)
                await writer.drain()
                writer.close()
                return

            port_bytes = await reader.readexactly(2)
            port = int.from_bytes(port_bytes, 'big')

            # Block private/internal targets
            if _is_blocked_url(f"http://{host}:{port}"):
                log.warning("SOCKS5 blocked connection to %s:%d (private network)", host, port)
                writer.write(b'\x05\x02\x00\x01' + b'\x00' * 6)  # connection not allowed
                await writer.drain()
                writer.close()
                return

            # 4. Connect to target
            try:
                remote_reader, remote_writer = await asyncio.wait_for(
                    asyncio.open_connection(host, port),
                    timeout=30,
                )
            except Exception:
                writer.write(b'\x05\x05\x00\x01' + b'\x00' * 6)  # connection refused
                await writer.drain()
                writer.close()
                return

            # 5. Send success response
            # BND.ADDR and BND.PORT (use zeros)
            writer.write(b'\x05\x00\x00\x01' + b'\x00\x00\x00\x00' + b'\x00\x00')
            await writer.drain()

            log.info("SOCKS5 CONNECT %s:%d \u2192 connected", host, port)
            self.proxy.request_count += 1

            # 6. Relay data bidirectionally
            await self._relay(reader, writer, remote_reader, remote_writer)

        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            log.debug("SOCKS5 session error: %s", e)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _relay(self, client_reader, client_writer, remote_reader, remote_writer):
        """Bidirectional data relay between client and remote"""
        async def pipe(src, dst, track_bytes=False):
            try:
                while True:
                    data = await src.read(65536)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
                    if track_bytes:
                        self.proxy.bytes_transferred += len(data)
            except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
                pass
            finally:
                try:
                    dst.close()
                except Exception:
                    pass

        await asyncio.gather(
            pipe(client_reader, remote_writer, track_bytes=True),
            pipe(remote_reader, client_writer, track_bytes=True),
        )

    async def start(self, host: str, port: int):
        self._server = await asyncio.start_server(self.handle_client, host, port)
        log.info("SOCKS5 proxy listening on %s:%d", host, port)

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()


# ---------------------------------------------------------------------------
# Parent communication
# ---------------------------------------------------------------------------

class ParentClient:
    def __init__(self, server_url: str, api_key: str):
        self.url = server_url.rstrip("/")
        self.headers = {"X-Worker-API-Key": api_key, "Content-Type": "application/json"}

    async def register(self, proxy_port: int, socks_port: int, public_ip: str | None) -> dict | None:
        geo = await get_ip_geo(public_ip) if public_ip else {}
        payload = {
            "hostname": socket.gethostname(),
            "public_ip": public_ip,
            "os_info": f"{platform.system()} {platform.release()}",
            "arch": platform.machine(),
            "python_version": platform.python_version(),
            "agent_version": VERSION,
            "tunnel_port": proxy_port,
            "socks_port": socks_port,
            "country": geo.get("country"),
            "city": geo.get("city"),
            "isp": geo.get("isp"),
            "machine_id": _get_machine_id(),
        }
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as s:
                async with s.post(f"{self.url}/api/worker-nodes/agent/register", json=payload, headers=self.headers) as r:
                    if r.status == 200:
                        data = await r.json()
                        log.info("Registered with parent as '%s' (id: %s)", data.get("name"), data.get("node_id"))
                        return data
                    log.error("Registration failed (%s): %s", r.status, await r.text())
        except Exception as e:
            log.error("Cannot reach parent: %s", e)
        return None

    async def heartbeat(self, proxy: ProxyHandler, proxy_port: int) -> dict | None:
        payload = {
            "public_ip": proxy._public_ip,
            "current_load": proxy.active_requests,
            "total_requests_proxied": proxy.request_count,
            "total_bytes_transferred": proxy.bytes_transferred,
            "avg_latency_ms": proxy.avg_latency_ms,
            "tunnel_port": proxy_port,
            "socks_port": proxy.socks_port,
            "agent_version": VERSION,
        }
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as s:
                async with s.post(f"{self.url}/api/worker-nodes/agent/heartbeat", json=payload, headers=self.headers) as r:
                    if r.status == 200:
                        return await r.json()
                    log.warning("Heartbeat failed (%s)", r.status)
        except Exception as e:
            log.warning("Heartbeat error: %s", e)
        return None

    async def disconnect(self):
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as s:
                async with s.post(f"{self.url}/api/worker-nodes/agent/disconnect", headers=self.headers):
                    log.info("Notified parent of disconnect")
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

async def heartbeat_loop(parent: ParentClient, proxy: ProxyHandler, port: int, interval: int):
    while True:
        await asyncio.sleep(interval)
        result = await parent.heartbeat(proxy, port)
        if result and not result.get("is_active", True):
            log.warning("Parent has disabled this minion")
        if result:
            # Check if parent indicates a newer version
            latest = result.get("latest_agent_version")
            if latest and latest != VERSION:
                log.warning("New agent version available: %s (current: %s)", latest, VERSION)
                # Auto-upgrade if parent requests it
                if result.get("upgrade_requested"):
                    log.info("Parent requested upgrade — starting auto-upgrade")
                    await proxy._self_upgrade()


async def run():
    cfg = load_config()
    server_url = cfg["server_url"]
    api_key = cfg["api_key"]
    proxy_port = cfg.get("proxy_port", 1080)

    log.info("Ghostwire Minion v%s", VERSION)
    log.info("Parent: %s", server_url)
    log.info("Proxy port: %s", proxy_port)

    socks_port = cfg.get("socks_port", proxy_port + 1)

    proxy = ProxyHandler(api_key, verify_ssl=cfg.get("verify_ssl", True))
    proxy.socks_port = socks_port
    parent = ParentClient(server_url, api_key)

    # Detect public IP once at startup
    proxy._public_ip = await get_public_ip()
    if proxy._public_ip:
        log.info("Public IP: %s", proxy._public_ip)

    # Register (retry up to 5 times)
    reg = None
    for attempt in range(5):
        reg = await parent.register(proxy_port, socks_port, proxy._public_ip)
        if reg:
            break
        wait = 5 * (attempt + 1)
        log.warning("Retry %d in %ds...", attempt + 1, wait)
        await asyncio.sleep(wait)

    if not reg:
        log.error("Could not register after 5 attempts — exiting")
        sys.exit(1)

    hb_interval = reg.get("heartbeat_interval_seconds", 30)

    # Start HTTP server
    app = web.Application()
    app.router.add_post("/proxy", proxy.handle_proxy)
    app.router.add_get("/health", proxy.handle_health)
    app.router.add_post("/destroy", proxy.handle_destroy)
    app.router.add_post("/upgrade", proxy.handle_upgrade)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", proxy_port)
    await site.start()
    log.info("Listening on 0.0.0.0:%d", proxy_port)

    # Start SOCKS5 proxy server
    socks5 = Socks5Server(proxy)
    await socks5.start("0.0.0.0", socks_port)
    log.info("SOCKS5 proxy on port %d", socks_port)

    # Graceful shutdown
    stop = asyncio.Event()

    def _quit(sig):
        log.info("Received %s — shutting down", sig.name)
        stop.set()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _quit, sig)

    hb_task = asyncio.create_task(heartbeat_loop(parent, proxy, proxy_port, hb_interval))

    await stop.wait()

    hb_task.cancel()
    await socks5.stop()
    await parent.disconnect()
    await runner.cleanup()
    log.info("Minion stopped.")


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
