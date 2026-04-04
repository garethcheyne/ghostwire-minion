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

import aiohttp
from aiohttp import web

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_FILE = Path(__file__).parent / "config.json"
VERSION = "1.0.0"

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
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.request_count = 0
        self.bytes_transferred = 0
        self.active_requests = 0
        self._latencies: list[float] = []
        self._public_ip: str | None = None

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
                    ssl=False,
                ) as resp:
                    resp_body = await resp.text()
                    resp_headers = dict(resp.headers)
                    elapsed = (time.monotonic() - t0) * 1000

                    self.request_count += 1
                    self.bytes_transferred += len(resp_body.encode())
                    self._latencies.append(elapsed)

                    return web.json_response({
                        "status_code": resp.status,
                        "headers": resp_headers,
                        "body": resp_body,
                        "elapsed_ms": round(elapsed, 2),
                        "worker_ip": self._public_ip or "unknown",
                    })
        except asyncio.TimeoutError:
            return web.json_response(
                {"error": "Request timed out", "elapsed_ms": round((time.monotonic() - t0) * 1000, 2)},
                status=504,
            )
        except Exception as e:
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
# Parent communication
# ---------------------------------------------------------------------------

class ParentClient:
    def __init__(self, server_url: str, api_key: str):
        self.url = server_url.rstrip("/")
        self.headers = {"X-Worker-API-Key": api_key, "Content-Type": "application/json"}

    async def register(self, proxy_port: int, public_ip: str | None) -> dict | None:
        geo = await get_ip_geo(public_ip) if public_ip else {}
        payload = {
            "hostname": socket.gethostname(),
            "public_ip": public_ip,
            "os_info": f"{platform.system()} {platform.release()}",
            "arch": platform.machine(),
            "python_version": platform.python_version(),
            "agent_version": VERSION,
            "tunnel_port": proxy_port,
            "country": geo.get("country"),
            "city": geo.get("city"),
            "isp": geo.get("isp"),
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


async def run():
    cfg = load_config()
    server_url = cfg["server_url"]
    api_key = cfg["api_key"]
    proxy_port = cfg.get("proxy_port", 1080)

    log.info("Ghostwire Minion v%s", VERSION)
    log.info("Parent: %s", server_url)
    log.info("Proxy port: %s", proxy_port)

    proxy = ProxyHandler(api_key)
    parent = ParentClient(server_url, api_key)

    # Detect public IP once at startup
    proxy._public_ip = await get_public_ip()
    if proxy._public_ip:
        log.info("Public IP: %s", proxy._public_ip)

    # Register (retry up to 5 times)
    reg = None
    for attempt in range(5):
        reg = await parent.register(proxy_port, proxy._public_ip)
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

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", proxy_port)
    await site.start()
    log.info("Listening on 0.0.0.0:%d", proxy_port)

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
    await parent.disconnect()
    await runner.cleanup()
    log.info("Minion stopped.")


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
