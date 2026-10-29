#!/usr/bin/env python3
"""
Ghostwire Minion: a lightweight proxy agent.

Registers with a Ghostwire parent server, sends it heartbeats, and relays requests from the parent
through this machine's IP address: HTTP requests through POST /proxy and TCP connections through a
SOCKS5 proxy on the next port up.

Runs on the distro's own Python, so it has to stay compatible with Python 3.10 and later.

Usage:
    python minion.py          (reads config.json in the same directory)
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import ipaddress
import json
import logging
import math
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

import aiohttp
from aiohttp import web
from aiohttp.abc import AbstractResolver
from aiohttp.resolver import ThreadedResolver
from yarl import URL

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable, Iterable

    from aiohttp.abc import ResolveResult

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address

# ---------------------------------------------------------------------------
# Paths, version and limits
# ---------------------------------------------------------------------------

INSTALL_DIR = Path(__file__).resolve().parent
CONFIG_FILE = INSTALL_DIR / "config.json"
VERSION_FILE = INSTALL_DIR / "VERSION"
SERVICE_NAME = "ghostwire-minion"
# Where install.sh puts the minion. /destroy only deletes files when it's running from here.
DEFAULT_INSTALL_DIR = Path("/opt/ghostwire-minion")
REPO_URL = "https://github.com/garethcheyne/ghostwire-minion.git"

MAX_CONCURRENT_REQUESTS = 50  # /proxy requests in flight; more get 429
MAX_REQUEST_BYTES = 1024**2  # largest /proxy request body accepted from the parent (aiohttp's default)
DEFAULT_PROXY_TIMEOUT = 30.0  # seconds, when the parent doesn't send one
MAX_PROXY_TIMEOUT = 300.0  # the most a single /proxy request may ask for
MAX_REDIRECTS = 10  # aiohttp's default
DEFAULT_MAX_RESPONSE_BYTES = 50 * 1024**2  # largest target response relayed back (config: max_response_bytes)
MAX_HEADERS = 100
MAX_URL_LENGTH = 8192

SOCKS_HANDSHAKE_TIMEOUT = 30.0  # seconds for the client to finish the SOCKS5 greeting and request
SOCKS_CONNECT_TIMEOUT = 30.0  # seconds to connect to the target
MAX_SOCKS_SESSIONS = 512
RELAY_BUFFER = 65536

MIN_HEARTBEAT_INTERVAL = 5
MAX_HEARTBEAT_INTERVAL = 3600
MAX_REGISTER_BACKOFF = 300

REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})
HTTP_TOKEN = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")  # RFC 9110 token: method and header names

# Read and connection errors that just mean the other side went away. A tuple, so the except
# clauses below keep their brackets under ruff format (except A, B: is Python 3.14 syntax).
CONNECTION_CLOSED = (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError)
TIMEOUT_ERRORS = (asyncio.TimeoutError, TimeoutError)

log = logging.getLogger("ghostwire-minion")


def _read_version() -> str:
    try:
        return VERSION_FILE.read_text(encoding="utf-8").strip() or "0.0.0"
    except OSError:
        return "0.0.0"


VERSION = _read_version()


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class ConfigError(Exception):
    """config.json is missing or invalid. The message never includes the API key."""


@dataclass(frozen=True)
class Config:
    server_url: str
    api_key: str = field(repr=False)
    proxy_port: int = 1080
    socks_port: int = 1081
    verify_ssl: bool = True
    max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES


def _port(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
        raise ConfigError(f"{name} must be a whole number from 1 to 65535")
    return value


def parse_config(raw: Any) -> Config:
    """Check config.json's contents and fill in the defaults."""
    if not isinstance(raw, dict):
        raise ConfigError("config.json must hold a JSON object")

    server_url = raw.get("server_url")
    if not isinstance(server_url, str) or not server_url.strip():
        raise ConfigError("server_url is missing")
    server_url = server_url.strip().rstrip("/")
    try:
        parsed = URL(server_url)
    except ValueError as exc:
        raise ConfigError(f"server_url isn't a valid URL: {exc}") from exc
    if parsed.scheme not in ("http", "https") or not parsed.host:
        raise ConfigError("server_url must be an http:// or https:// URL")

    api_key = raw.get("api_key")
    if not isinstance(api_key, str) or not api_key:
        raise ConfigError("api_key is missing")
    if any(c.isspace() or not c.isprintable() for c in api_key):
        raise ConfigError("api_key contains spaces or control characters")

    proxy_port = _port(raw.get("proxy_port", 1080), "proxy_port")
    socks_port = _port(raw.get("socks_port", proxy_port + 1), "socks_port")
    if socks_port == proxy_port:
        raise ConfigError("socks_port must differ from proxy_port")

    verify_ssl = raw.get("verify_ssl", True)
    if not isinstance(verify_ssl, bool):
        raise ConfigError("verify_ssl must be true or false")

    max_response_bytes = raw.get("max_response_bytes", DEFAULT_MAX_RESPONSE_BYTES)
    if isinstance(max_response_bytes, bool) or not isinstance(max_response_bytes, int) or max_response_bytes < 1:
        raise ConfigError("max_response_bytes must be a positive whole number")

    return Config(
        server_url=server_url,
        api_key=api_key,
        proxy_port=proxy_port,
        socks_port=socks_port,
        verify_ssl=verify_ssl,
        max_response_bytes=max_response_bytes,
    )


def load_config(path: Path = CONFIG_FILE) -> Config:
    if not path.is_file():
        raise ConfigError(f"{path} not found: run install.sh first")
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"Can't read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        # Only the position: the message must not echo the file, which holds the API key.
        raise ConfigError(f"{path} isn't valid JSON (line {exc.lineno}, column {exc.colno})") from exc
    config = parse_config(raw)

    with contextlib.suppress(OSError):
        if sys.platform != "win32" and path.stat().st_mode & 0o077:
            log.warning("%s can be read by other users; it holds the API key (chmod 600 %s)", path, path)
    if URL(config.server_url).scheme != "https":
        log.warning("server_url uses plain http: the API key is sent to the parent unencrypted")
    if not config.verify_ssl:
        log.warning("verify_ssl is false: TLS certificates of proxied targets aren't checked")
    return config


def redact_url(url: str | URL) -> str:
    """scheme://host[:port]/path, without credentials, query or fragment, for logs."""
    try:
        u = URL(str(url))
    except ValueError:
        return "<invalid url>"
    if not u.host:
        return "<invalid url>"
    host = f"[{u.host}]" if ":" in u.host else u.host
    port = f":{u.explicit_port}" if u.explicit_port else ""
    return f"{u.scheme}://{host}{port}{u.raw_path}"[:200]


# ---------------------------------------------------------------------------
# Target checks: no internal or private networks
# ---------------------------------------------------------------------------

_BLOCKED_HOSTNAMES = frozenset({"localhost", "localhost.localdomain", "ip6-localhost", "ip6-loopback"})
_NAT64 = ipaddress.ip_network("64:ff9b::/96")
# This host's own public address: reaching it from here goes round the outside firewall.
_SELF_ADDRESSES: set[IPAddress] = set()


class BlockedTargetError(OSError):
    """The target is on an internal, private or otherwise non-public network."""


def parse_ip(value: str | None) -> IPAddress | None:
    """An IP address from a host or peer string (IPv6 brackets and zone allowed), or None."""
    if not value:
        return None
    text = value.strip()
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        return ip.ipv4_mapped
    return ip


def is_blocked_ip(ip: IPAddress) -> bool:
    """True for anything that isn't a public unicast address, and for this host's public IP."""
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped:
            return is_blocked_ip(ip.ipv4_mapped)
        if ip in _NAT64:  # NAT64 reaches the IPv4 address in the last 32 bits
            return is_blocked_ip(ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF))
        if ip.sixtofour and is_blocked_ip(ip.sixtofour):
            return True
        if ip.scope_id:
            return True
    if ip in _SELF_ADDRESSES:
        return True
    return ip.is_multicast or not ip.is_global


def is_blocked_hostname(host: str) -> bool:
    name = host.lower().rstrip(".")
    return name in _BLOCKED_HOSTNAMES or name.endswith(".localhost")


def url_block_reason(url: URL) -> str | None:
    """Why a proxied URL isn't allowed, or None. Names are checked again when they're resolved."""
    if url.scheme not in ("http", "https"):
        return "Only http:// and https:// URLs can be proxied"
    if not url.host:
        return "URL has no host"
    ip = parse_ip(url.host)
    if ip is not None:
        if is_blocked_ip(ip):
            return "Target URL is blocked (internal/private network)"
    elif is_blocked_hostname(url.host):
        return "Target URL is blocked (internal/private network)"
    return None


def _is_blocked_error(exc: BaseException | None) -> bool:
    """True if an aiohttp error was caused by GuardedResolver refusing an address."""
    seen = 0
    while exc is not None and seen < 10:
        if isinstance(exc, BlockedTargetError):
            return True
        nxt = getattr(exc, "os_error", None)
        exc = nxt if isinstance(nxt, BaseException) and nxt is not exc else (exc.__cause__ or exc.__context__)
        seen += 1
    return False


class GuardedResolver(AbstractResolver):
    """aiohttp resolver that refuses names resolving to internal addresses.

    aiohttp connects to exactly the addresses a resolver returns, so the check can't be bypassed by
    a name that resolves differently the second time (DNS rebinding). IP literals don't go through
    a resolver; url_block_reason() checks those before each request and each redirect.
    """

    def __init__(self) -> None:
        self._inner = ThreadedResolver()

    async def resolve(
        self, host: str, port: int = 0, family: socket.AddressFamily = socket.AF_INET
    ) -> list[ResolveResult]:
        if is_blocked_hostname(host):
            raise BlockedTargetError(f"{host} is an internal name")
        results = await self._inner.resolve(host, port, family)
        for result in results:
            ip = parse_ip(result["host"])
            if ip is None or is_blocked_ip(ip):
                raise BlockedTargetError(f"{host} resolves to an internal or private address")
        return results

    async def close(self) -> None:
        await self._inner.close()


def _get_machine_id() -> str:
    """A stable machine identifier (hashed, so the raw machine-id isn't sent anywhere)."""
    for path in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            with open(path, encoding="utf-8") as f:
                return hashlib.sha256(f.read().strip().encode()).hexdigest()[:32]
        except OSError:
            continue
    try:
        return hashlib.sha256(f"{socket.gethostname()}-{platform.machine()}".encode()).hexdigest()[:32]
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# SOCKS5 allowlist
# ---------------------------------------------------------------------------


class Allowlist:
    """Source IPs allowed to use the SOCKS5 proxy.

    The parent manages it: its server_ips come with registration and every heartbeat, and the source
    IP of each request that authenticates with the API key is added. An empty list lets nobody in.
    """

    def __init__(self) -> None:
        self._ips: set[IPAddress] = set()

    def add(self, value: Any, source: str) -> bool:
        ip = parse_ip(value) if isinstance(value, str) else None
        if ip is None:
            log.warning("SOCKS5 allowlist: ignored %r from %s (not an IP address)", value, source)
            return False
        if ip in self._ips:
            return False
        self._ips.add(ip)
        log.info("SOCKS5 allowlisted %s (%s)", ip, source)
        return True

    def add_all(self, values: Any, source: str) -> None:
        if not isinstance(values, list):
            if values is not None:
                log.warning("SOCKS5 allowlist: server_ips from %s isn't a list; ignored", source)
            return
        for value in values:
            self.add(value, source)

    def allows(self, value: str | None) -> bool:
        ip = parse_ip(value)
        return ip is not None and ip in self._ips

    def __len__(self) -> int:
        return len(self._ips)

    def as_list(self) -> list[str]:
        return sorted(str(ip) for ip in self._ips)


# ---------------------------------------------------------------------------
# IP and geo lookup
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
                    if r.status != 200:
                        continue
                    d = await r.json(content_type=None)
                    value = (d.get("ip") or d.get("query")) if isinstance(d, dict) else None
                    if isinstance(value, str) and parse_ip(value):
                        return str(parse_ip(value))
            except Exception as exc:
                log.debug("Public IP lookup via %s failed: %s", url, exc)
    return None


async def get_ip_geo(ip: str) -> dict[str, str | None]:
    try:
        async with (
            aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as s,
            s.get(f"https://ipinfo.io/{ip}/json") as r,
        ):
            if r.status == 200:
                d = await r.json(content_type=None)
                if isinstance(d, dict):
                    return {
                        "country": str(d.get("country") or ""),
                        "city": f"{d.get('city', '')}, {d.get('region', '')}".strip(", "),
                        "isp": str(d.get("org") or ""),
                    }
    except Exception as exc:
        log.debug("Geo lookup failed: %s", exc)
    return {"country": None, "city": None, "isp": None}


def _version_key(version: str) -> tuple[int, ...] | None:
    parts = version.strip().lstrip("v").split(".")
    return tuple(int(p) for p in parts) if parts and all(p.isdigit() for p in parts) else None


def is_newer_version(latest: Any, current: str | None = None) -> bool:
    """Dated versions (2026.10.29.2149) compare as numbers; anything else isn't treated as newer."""
    if not isinstance(latest, str):
        return False
    latest_key, current_key = _version_key(latest), _version_key(VERSION if current is None else current)
    return latest_key is not None and current_key is not None and latest_key > current_key


# ---------------------------------------------------------------------------
# /proxy requests
# ---------------------------------------------------------------------------


class RequestError(ValueError):
    """A /proxy request from the parent that can't be carried out (400)."""


class ResponseTooLargeError(Exception):
    pass


@dataclass
class ProxyRequest:
    url: URL
    method: str = "GET"
    headers: dict[str, str] = field(default_factory=dict)
    body: str | dict[str, Any] | None = None
    timeout: float = DEFAULT_PROXY_TIMEOUT
    follow_redirects: bool = True


def parse_proxy_request(data: Any) -> ProxyRequest:
    """Check a /proxy request body and turn it into a ProxyRequest. Raises RequestError."""
    if not isinstance(data, dict):
        raise RequestError("Request body must be a JSON object")

    raw_url = data.get("url")
    if not raw_url:
        raise RequestError("url is required")
    if not isinstance(raw_url, str) or len(raw_url) > MAX_URL_LENGTH:
        raise RequestError("url must be a string of at most 8192 characters")
    try:
        url = URL(raw_url)
    except ValueError as exc:
        raise RequestError(f"url is invalid: {exc}") from exc
    if url.scheme not in ("http", "https") or not url.host:
        raise RequestError("url must be an absolute http:// or https:// URL")

    method = data.get("method", "GET")
    if not isinstance(method, str) or len(method) > 32 or not HTTP_TOKEN.match(method):
        raise RequestError("method must be an HTTP method name")
    method = method.upper()

    raw_headers = data.get("headers") or {}
    if not isinstance(raw_headers, dict) or len(raw_headers) > MAX_HEADERS:
        raise RequestError("headers must be an object of at most 100 headers")
    headers: dict[str, str] = {}
    for name, value in raw_headers.items():
        if not isinstance(name, str) or not HTTP_TOKEN.match(name):
            raise RequestError(f"Invalid header name: {str(name)[:50]!r}")
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            raise RequestError(f"Header {name} must be a string")
        text = str(value)
        if any(c in text for c in "\r\n\0"):
            raise RequestError(f"Header {name} contains a line break")
        headers[name] = text

    # aiohttp can't decode brotli, so don't ask for it.
    for name in list(headers):
        if name.lower() == "accept-encoding":
            headers[name] = ", ".join(
                p.strip() for p in headers[name].split(",") if p.strip() and p.strip().split(";")[0].lower() != "br"
            )

    body = data.get("body")
    if body is not None and not isinstance(body, (str, dict)):
        raise RequestError("body must be a string")

    timeout = data.get("timeout", DEFAULT_PROXY_TIMEOUT)
    if timeout is None:
        timeout = DEFAULT_PROXY_TIMEOUT
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise RequestError("timeout must be a positive number of seconds")
    timeout = min(float(timeout), MAX_PROXY_TIMEOUT)

    follow = data.get("follow_redirects", True)
    if follow is None:
        follow = True
    if not isinstance(follow, bool):
        raise RequestError("follow_redirects must be true or false")

    return ProxyRequest(url=url, method=method, headers=headers, body=body, timeout=timeout, follow_redirects=follow)


def _decode_body(raw: bytes, charset: str | None) -> str:
    if charset:
        with contextlib.suppress(LookupError):
            return raw.decode(charset, errors="replace")
    return raw.decode("utf-8", errors="replace")


async def fetch(
    req: ProxyRequest, *, verify_ssl: bool, max_response_bytes: int
) -> tuple[int, dict[str, str], bytes, str]:
    """Make the request from this machine. Returns status, headers, raw body and decoded text.

    Redirects are followed here rather than by aiohttp, so every hop is checked before it's requested.
    """
    connector = aiohttp.TCPConnector(resolver=GuardedResolver(), ssl=verify_ssl)
    timeout = aiohttp.ClientTimeout(total=req.timeout)
    url, method, body, headers = req.url, req.method, req.body, dict(req.headers)
    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        for hop in range(MAX_REDIRECTS + 1):
            reason = url_block_reason(url)
            if reason:
                raise BlockedTargetError(reason)
            async with session.request(method, url, headers=headers, data=body, allow_redirects=False) as resp:
                location = resp.headers.get("Location")
                if req.follow_redirects and resp.status in REDIRECT_STATUSES and location:
                    if hop == MAX_REDIRECTS:
                        raise aiohttp.TooManyRedirects(resp.request_info, ())
                    next_url = resp.url.join(URL(location))
                    # The same method changes aiohttp makes when it follows redirects itself.
                    if (resp.status == 303 and method != "HEAD") or (resp.status in (301, 302) and method == "POST"):
                        method, body = "GET", None
                        headers = {k: v for k, v in headers.items() if k.lower() != "content-length"}
                    if next_url.origin() != url.origin():
                        headers = {
                            k: v
                            for k, v in headers.items()
                            if k.lower() not in ("authorization", "proxy-authorization")
                        }
                    url = next_url
                    continue

                raw = bytearray()
                async for chunk in resp.content.iter_chunked(RELAY_BUFFER):
                    raw += chunk
                    if len(raw) > max_response_bytes:
                        raise ResponseTooLargeError(f"Response body is larger than {max_response_bytes} bytes")
                return resp.status, dict(resp.headers), bytes(raw), _decode_body(bytes(raw), resp.charset)
    raise AssertionError("unreachable")  # pragma: no cover


# ---------------------------------------------------------------------------
# HTTP API: /proxy, /health, /destroy, /upgrade
# ---------------------------------------------------------------------------


class ProxyHandler:
    def __init__(
        self,
        api_key: str,
        verify_ssl: bool = True,
        *,
        allowlist: Allowlist | None = None,
        max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
    ) -> None:
        self.api_key = api_key
        self.verify_ssl = verify_ssl
        self.max_response_bytes = max_response_bytes
        self.allowlist = allowlist if allowlist is not None else Allowlist()
        self.request_count = 0
        self.bytes_transferred = 0
        self.active_requests = 0
        self.max_concurrent = MAX_CONCURRENT_REQUESTS
        self._latencies: deque[float] = deque(maxlen=100)
        self._public_ip: str | None = None
        self.socks_port: int = 0
        self._background: set[asyncio.Task[Any]] = set()
        self._lifecycle_started_at: float | None = None

    @property
    def avg_latency_ms(self) -> float | None:
        if not self._latencies:
            return None
        return sum(self._latencies) / len(self._latencies)

    def is_authorised(self, request: web.Request) -> bool:
        supplied = request.headers.get("X-Minion-API-Key", "")
        return hmac.compare_digest(
            supplied.encode("utf-8", "surrogateescape"), self.api_key.encode("utf-8", "surrogateescape")
        )

    def learn_parent_ip(self, request: web.Request) -> None:
        """Allowlist the source IP of an authenticated API request for SOCKS5."""
        peername = request.transport.get_extra_info("peername") if request.transport else None
        if peername:
            self.allowlist.add(peername[0], "authenticated API request")

    async def handle_proxy(self, request: web.Request) -> web.Response:
        """Relay a request from the Ghostwire parent through this IP."""
        if self.active_requests >= self.max_concurrent:
            return web.json_response({"error": "Rate limit exceeded — too many concurrent requests"}, status=429)
        self.active_requests += 1
        t0 = time.monotonic()
        try:
            try:
                data = await request.json()
            except Exception:
                return web.json_response({"error": "Invalid JSON"}, status=400)
            try:
                req = parse_proxy_request(data)
            except RequestError as exc:
                return web.json_response({"error": str(exc)}, status=400)
            reason = url_block_reason(req.url)
            if reason:
                return web.json_response({"error": reason}, status=403)
            return await self._relay(req, t0)
        finally:
            self.active_requests -= 1

    async def _relay(self, req: ProxyRequest, t0: float) -> web.Response:
        target = redact_url(req.url)

        def elapsed_ms() -> float:
            return round((time.monotonic() - t0) * 1000, 2)

        try:
            status, headers, raw, text = await fetch(
                req, verify_ssl=self.verify_ssl, max_response_bytes=self.max_response_bytes
            )
        except TIMEOUT_ERRORS:
            log.warning("PROXY %s %s → TIMEOUT (%.0fms)", req.method, target, elapsed_ms())
            return web.json_response({"error": "Request timed out", "elapsed_ms": elapsed_ms()}, status=504)
        except Exception as exc:
            if _is_blocked_error(exc):
                log.warning("PROXY %s %s → BLOCKED (internal/private address)", req.method, target)
                return web.json_response({"error": "Target URL is blocked (internal/private network)"}, status=403)
            log.warning("PROXY %s %s → ERROR: %s (%.0fms)", req.method, target, exc, elapsed_ms())
            return web.json_response({"error": str(exc) or type(exc).__name__, "elapsed_ms": elapsed_ms()}, status=502)

        elapsed = elapsed_ms()
        self.request_count += 1
        self.bytes_transferred += len(raw)
        self._latencies.append(elapsed)
        log.info("PROXY %s %s → %d (%.0fms, %d bytes)", req.method, target, status, elapsed, len(raw))
        return web.json_response(
            {
                "status_code": status,
                "headers": headers,
                "body": text,
                "elapsed_ms": elapsed,
                "worker_ip": self._public_ip or "unknown",
            }
        )

    async def handle_health(self, _request: web.Request) -> web.Response:
        return web.json_response(
            {
                "status": "ok",
                "version": VERSION,
                "requests_proxied": self.request_count,
                "active_requests": self.active_requests,
                "socks_port": self.socks_port or None,
                "socks_allowed_ips": self.allowlist.as_list(),
            }
        )

    async def handle_destroy(self, request: web.Request) -> web.StreamResponse:
        """Self-destruct: stop the service, remove it and its files."""
        log.warning("DESTROY command received — removing this minion")
        resp = web.json_response({"status": "destroying", "message": "Minion is removing itself"})
        await resp.prepare(request)
        await resp.write_eof()
        self._later(self._destroy)
        return resp

    async def handle_upgrade(self, request: web.Request) -> web.StreamResponse:
        """Upgrade to the latest release (scripts/upgrade.sh), which restarts the service."""
        log.info("UPGRADE command received — starting upgrade")
        resp = web.json_response(
            {
                "status": "upgrading",
                "current_version": VERSION,
                "message": "Pulling latest code and restarting",
            }
        )
        await resp.prepare(request)
        await resp.write_eof()
        self._later(self.upgrade)
        return resp

    def _later(self, job: Callable[[], Awaitable[None]], delay: float = 1.0) -> None:
        """Run job shortly, after the response has gone, keeping a reference to its task."""

        def start() -> None:
            task = asyncio.ensure_future(job())
            self._background.add(task)
            task.add_done_callback(self._background.discard)

        asyncio.get_running_loop().call_later(delay, start)

    def _claim_lifecycle(self) -> bool:
        """One upgrade or removal at a time. A claim lapses after 15 minutes, in case the upgrade
        script failed without restarting the service."""
        now = time.monotonic()
        if self._lifecycle_started_at is not None and now - self._lifecycle_started_at < 900:
            log.info("An upgrade or removal is already under way")
            return False
        self._lifecycle_started_at = now
        return True

    async def upgrade(self) -> None:
        if not self._claim_lifecycle():
            return
        try:
            started = await asyncio.to_thread(start_upgrade)
        except Exception:
            log.exception("Upgrade failed")
            started = False
        if not started:
            self._lifecycle_started_at = None

    async def _destroy(self) -> None:
        if not self._claim_lifecycle():
            return
        try:
            started = await asyncio.to_thread(start_destroy)
        except Exception:
            log.exception("Self-destruct failed")
            started = False
        if not started:
            self._lifecycle_started_at = None


def build_app(proxy: ProxyHandler) -> web.Application:
    """The minion's HTTP API. Everything except GET /health needs the X-Minion-API-Key header."""

    @web.middleware
    async def require_api_key(
        request: web.Request, handler: Callable[[web.Request], Awaitable[web.StreamResponse]]
    ) -> web.StreamResponse:
        if request.path == "/health" and request.method in ("GET", "HEAD"):
            return await handler(request)
        if not proxy.is_authorised(request):
            peer = request.transport.get_extra_info("peername") if request.transport else None
            log.warning(
                "Rejected %s %s from %s: missing or wrong API key", request.method, request.path, peer and peer[0]
            )
            return web.json_response({"error": "Unauthorized"}, status=401)
        proxy.learn_parent_ip(request)
        return await handler(request)

    app = web.Application(middlewares=[require_api_key], client_max_size=MAX_REQUEST_BYTES)
    app.router.add_post("/proxy", proxy.handle_proxy)
    app.router.add_get("/health", proxy.handle_health)
    app.router.add_post("/destroy", proxy.handle_destroy)
    app.router.add_post("/upgrade", proxy.handle_upgrade)
    return app


# ---------------------------------------------------------------------------
# Upgrade and self-destruct
# ---------------------------------------------------------------------------


def _systemd_running() -> bool:
    return Path("/run/systemd/system").is_dir() and shutil.which("systemd-run") is not None


def run_detached(argv: list[str], name: str) -> bool:
    """Start a command that outlives this process and its service.

    Under systemd it runs as a transient unit (systemd-run), outside this service's cgroup and
    sandbox, so stopping the service doesn't kill it and it can write outside the install folder.
    Elsewhere (OpenRC) it runs in a new session, which stopping the service doesn't touch.
    """
    try:
        if _systemd_running():
            unit = f"{name}-{int(time.time())}"
            subprocess.run(  # noqa: S603  fixed argument list, no shell
                [shutil.which("systemd-run") or "systemd-run", f"--unit={unit}", "--collect", "--quiet", *argv],
                check=True,
                capture_output=True,
                timeout=30,
            )
            log.info("Started %s as systemd unit %s", argv[0], unit)
        else:
            subprocess.Popen(  # noqa: S603  fixed argument list, no shell
                argv,
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd="/",
            )
            log.info("Started %s", argv[0])
        return True
    except (OSError, subprocess.SubprocessError) as exc:
        detail = getattr(exc, "stderr", b"") or b""
        log.error("Couldn't start %s: %s %s", argv[0], exc, detail.decode(errors="replace").strip())
        return False


def start_upgrade() -> bool:
    """Start an upgrade. Blocking; call it in a thread. True when the upgrade was started."""
    script = INSTALL_DIR / "scripts" / "upgrade.sh"
    bash = shutil.which("bash")
    if script.is_file() and bash:
        # The suite's upgrade script: backs up, downloads the release, runs its install.sh, checks
        # health, and stops and starts this service itself. Its log goes to backups/.
        return run_detached([bash, str(script), "--yes"], f"{SERVICE_NAME}-upgrade")
    log.info("No scripts/upgrade.sh here, so upgrading in place")
    return _upgrade_in_place()


def _upgrade_in_place() -> bool:
    """Upgrade for installs from before scripts/upgrade.sh: copy the new code in and restart."""
    git = shutil.which("git")
    if not git:
        log.error("Upgrade needs git, which isn't installed")
        return False
    tmp = Path(tempfile.mkdtemp(prefix="gw-minion-upgrade-"))
    try:
        log.info("Cloning latest from %s", REPO_URL)
        result = subprocess.run(  # noqa: S603  fixed argument list, no shell
            [git, "clone", "--quiet", "--depth", "1", REPO_URL, str(tmp / "src")],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            log.error("git clone failed: %s", result.stderr.strip())
            return False
        src = tmp / "src"
        for name in ("minion.py", "requirements.txt", "install.sh", "VERSION", "scripts/upgrade.sh"):
            if (src / name).is_file():
                dest = INSTALL_DIR / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                staged = dest.with_name(dest.name + ".new")
                shutil.copy2(src / name, staged)
                staged.replace(dest)
                log.info("Updated %s", name)
        pip = INSTALL_DIR / "venv" / "bin" / "pip"
        if pip.exists():
            log.info("Installing requirements...")
            result = subprocess.run(  # noqa: S603  fixed argument list, no shell
                [str(pip), "install", "--quiet", "-r", str(INSTALL_DIR / "requirements.txt")],
                capture_output=True,
                text=True,
                timeout=300,
            )
            if result.returncode != 0:
                log.error("pip install failed: %s", result.stderr.strip()[-500:])
    except (OSError, subprocess.SubprocessError) as exc:
        log.error("Upgrade failed: %s", exc)
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    log.info("Upgrade complete: %s -> %s — restarting service", VERSION, _read_version())
    if _systemd_running() and shutil.which("systemctl"):
        argv = [shutil.which("systemctl") or "systemctl", "restart", "--no-block", SERVICE_NAME]
        with contextlib.suppress(OSError, subprocess.SubprocessError):
            if subprocess.run(argv, capture_output=True, timeout=30).returncode == 0:  # noqa: S603  fixed arguments
                return True
    elif shutil.which("rc-service") and run_detached(
        [shutil.which("rc-service") or "rc-service", SERVICE_NAME, "restart"], f"{SERVICE_NAME}-restart"
    ):
        return True
    # No service manager to restart through: exit, and a supervisor (systemd Restart=always) starts the new code.
    logging.shutdown()
    os._exit(0)


_DESTROY_SYSTEMD = (
    'systemctl disable --now "$1"; rm -f "/etc/systemd/system/$1.service"; systemctl daemon-reload; '
    '[ -z "$2" ] || rm -rf "$2"'
)
_DESTROY_OPENRC = 'rc-service "$1" stop; rc-update del "$1" default; rm -f "/etc/init.d/$1"; [ -z "$2" ] || rm -rf "$2"'


def start_destroy() -> bool:
    """Remove the service and its files. Blocking; call it in a thread."""
    remove_dir = str(DEFAULT_INSTALL_DIR) if INSTALL_DIR == DEFAULT_INSTALL_DIR else ""
    if not remove_dir:
        log.warning(
            "Running from %s, not %s: the service is removed but the files are kept", INSTALL_DIR, DEFAULT_INSTALL_DIR
        )
    sh = shutil.which("sh") or "/bin/sh"
    if _systemd_running():
        script = _DESTROY_SYSTEMD
    elif shutil.which("rc-service"):
        script = _DESTROY_OPENRC
    else:
        log.error("Neither systemd nor OpenRC is running here, so the minion can't remove itself")
        return False
    # The uninstaller runs outside this service (run_detached), so stopping the service doesn't stop it.
    return run_detached(
        [sh, "-c", script, f"{SERVICE_NAME}-destroy", SERVICE_NAME, remove_dir], f"{SERVICE_NAME}-destroy"
    )


# ---------------------------------------------------------------------------
# SOCKS5 proxy server (RFC 1928, no-auth, CONNECT only)
# ---------------------------------------------------------------------------

SOCKS_OK = 0x00
SOCKS_GENERAL_FAILURE = 0x01
SOCKS_NOT_ALLOWED = 0x02
SOCKS_HOST_UNREACHABLE = 0x04
SOCKS_CONNECTION_REFUSED = 0x05
SOCKS_COMMAND_NOT_SUPPORTED = 0x07
SOCKS_ADDRESS_NOT_SUPPORTED = 0x08


def socks_reply(code: int) -> bytes:
    """A SOCKS5 reply with BND.ADDR 0.0.0.0 and BND.PORT 0."""
    return bytes([0x05, code, 0x00, 0x01]) + b"\x00" * 6


class Socks5Server:
    """Minimal SOCKS5 proxy server (RFC 1928, no-auth, CONNECT only).

    Only source IPs on the allowlist get in; an empty allowlist lets nobody in. Targets on internal or
    private networks are refused, whether named by IP or by a name that resolves to one.
    """

    def __init__(self, proxy: ProxyHandler, allowlist: Allowlist, max_sessions: int = MAX_SOCKS_SESSIONS) -> None:
        self.proxy = proxy
        self.allowlist = allowlist
        self.max_sessions = max_sessions
        self._server: asyncio.AbstractServer | None = None
        self._sessions: set[asyncio.Task[Any]] = set()
        self._rejected_logged: dict[str, float] = {}

    def _log_rejected(self, client_ip: str | None) -> None:
        # The port is open to the internet; log each rejected address at most every 10 minutes.
        key = client_ip or "?"
        now = time.monotonic()
        if now - self._rejected_logged.get(key, -1e9) < 600:
            return
        if len(self._rejected_logged) > 1000:
            self._rejected_logged.clear()
        self._rejected_logged[key] = now
        log.warning("SOCKS5 rejected connection from %s (not in allowlist)", client_ip)

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Handle one SOCKS5 client connection."""
        peer = writer.get_extra_info("peername")
        client_ip = peer[0] if peer else None
        if not self.allowlist.allows(client_ip):
            self._log_rejected(client_ip)
            writer.close()
            return
        if len(self._sessions) >= self.max_sessions:
            log.warning("SOCKS5 rejected connection from %s (%d sessions open)", client_ip, len(self._sessions))
            writer.close()
            return

        task = asyncio.current_task()
        if task is not None:
            self._sessions.add(task)
        remote_writer: asyncio.StreamWriter | None = None
        try:
            remote = await asyncio.wait_for(
                self._negotiate(reader, writer), SOCKS_HANDSHAKE_TIMEOUT + SOCKS_CONNECT_TIMEOUT
            )
            if remote is None:
                return
            remote_reader, remote_writer = remote
            await self._relay(reader, writer, remote_reader, remote_writer)
        except CONNECTION_CLOSED:
            pass
        except TIMEOUT_ERRORS:
            log.debug("SOCKS5 handshake from %s timed out", client_ip)
        except Exception as exc:
            log.debug("SOCKS5 session error: %s", exc)
        finally:
            if task is not None:
                self._sessions.discard(task)
            for w in (writer, remote_writer):
                if w is not None:
                    with contextlib.suppress(Exception):
                        w.close()

    async def _negotiate(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter] | None:
        """Greeting, request and connect. Returns the target's streams, or None after replying with an error."""

        async def fail(code: int) -> None:
            writer.write(socks_reply(code))
            await writer.drain()

        # 1. Greeting: version, number of methods, methods. Only "no authentication" is offered.
        version, nmethods = await asyncio.wait_for(reader.readexactly(2), SOCKS_HANDSHAKE_TIMEOUT)
        if version != 0x05:
            return None
        methods = await asyncio.wait_for(reader.readexactly(nmethods), SOCKS_HANDSHAKE_TIMEOUT)
        if 0x00 not in methods:
            writer.write(b"\x05\xff")  # no acceptable methods
            await writer.drain()
            return None
        writer.write(b"\x05\x00")
        await writer.drain()

        # 2. Request: version, command, reserved, address type, address, port.
        version, cmd, _reserved, atyp = await asyncio.wait_for(reader.readexactly(4), SOCKS_HANDSHAKE_TIMEOUT)
        if version != 0x05:
            return None
        if atyp == 0x01:
            host = socket.inet_ntop(
                socket.AF_INET, await asyncio.wait_for(reader.readexactly(4), SOCKS_HANDSHAKE_TIMEOUT)
            )
        elif atyp == 0x03:
            length = (await asyncio.wait_for(reader.readexactly(1), SOCKS_HANDSHAKE_TIMEOUT))[0]
            raw_host = await asyncio.wait_for(reader.readexactly(length), SOCKS_HANDSHAKE_TIMEOUT)
            try:
                host = raw_host.decode("utf-8")
            except UnicodeDecodeError:
                await fail(SOCKS_GENERAL_FAILURE)
                return None
        elif atyp == 0x04:
            host = socket.inet_ntop(
                socket.AF_INET6, await asyncio.wait_for(reader.readexactly(16), SOCKS_HANDSHAKE_TIMEOUT)
            )
        else:
            await fail(SOCKS_ADDRESS_NOT_SUPPORTED)
            return None
        port = int.from_bytes(await asyncio.wait_for(reader.readexactly(2), SOCKS_HANDSHAKE_TIMEOUT), "big")
        if cmd != 0x01:
            await fail(SOCKS_COMMAND_NOT_SUPPORTED)
            return None

        # 3. Check the target, then connect to the exact addresses that were checked.
        try:
            addresses = await resolve_socks_target(host, port)
        except BlockedTargetError:
            log.warning("SOCKS5 blocked connection to %s:%d (internal/private network)", host, port)
            await fail(SOCKS_NOT_ALLOWED)
            return None
        except OSError:
            await fail(SOCKS_HOST_UNREACHABLE)
            return None
        try:
            remote = await asyncio.wait_for(_connect_any(addresses, port), SOCKS_CONNECT_TIMEOUT)
        except (OSError, *TIMEOUT_ERRORS) as _failed:
            await fail(SOCKS_CONNECTION_REFUSED)
            return None

        writer.write(socks_reply(SOCKS_OK))
        await writer.drain()
        log.info("SOCKS5 CONNECT %s:%d → connected", host, port)
        self.proxy.request_count += 1
        return remote

    async def _relay(
        self,
        client_reader: asyncio.StreamReader,
        client_writer: asyncio.StreamWriter,
        remote_reader: asyncio.StreamReader,
        remote_writer: asyncio.StreamWriter,
    ) -> None:
        """Copy data both ways until either side closes."""

        async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
            try:
                while data := await src.read(RELAY_BUFFER):
                    dst.write(data)
                    await dst.drain()
                    self.proxy.bytes_transferred += len(data)
            except CONNECTION_CLOSED:
                pass
            finally:
                with contextlib.suppress(Exception):
                    dst.close()

        await asyncio.gather(pipe(client_reader, remote_writer), pipe(remote_reader, client_writer))

    async def start(self, host: str, port: int) -> None:
        self._server = await asyncio.start_server(self.handle_client, host, port)
        log.info("SOCKS5 proxy listening on %s:%d", host, port)

    async def stop(self) -> None:
        if self._server:
            self._server.close()
        for task in list(self._sessions):
            task.cancel()
        if self._sessions:
            await asyncio.gather(*self._sessions, return_exceptions=True)
        if self._server:
            with contextlib.suppress(*TIMEOUT_ERRORS):
                await asyncio.wait_for(self._server.wait_closed(), 5)


async def resolve_socks_target(host: str, port: int) -> list[str]:
    """The addresses to connect to for a SOCKS5 target. Raises BlockedTargetError if any is internal."""
    ip = parse_ip(host)
    if ip is not None:
        if is_blocked_ip(ip):
            raise BlockedTargetError(host)
        return [str(ip)]
    if not host or is_blocked_hostname(host):
        raise BlockedTargetError(host)
    infos = await asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM)
    addresses: list[str] = []
    for info in infos:
        address = str(info[4][0])
        resolved = parse_ip(address)
        if resolved is None or is_blocked_ip(resolved):
            raise BlockedTargetError(host)  # fail closed if any answer is internal
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise OSError(f"{host} has no addresses")
    return addresses


async def _connect_any(addresses: Iterable[str], port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    last: OSError | None = None
    for address in addresses:
        try:
            return await asyncio.open_connection(address, port)
        except OSError as exc:
            last = exc
    raise last or OSError("no addresses")


# ---------------------------------------------------------------------------
# Parent communication
# ---------------------------------------------------------------------------


class ParentClient:
    """Registration, heartbeats and disconnect, authenticated with X-Worker-API-Key.

    TLS certificates of the parent are always verified (verify_ssl only applies to proxied targets).
    """

    def __init__(self, server_url: str, api_key: str) -> None:
        self.url = server_url.rstrip("/")
        self.headers = {"X-Worker-API-Key": api_key, "Content-Type": "application/json"}
        self._session: aiohttp.ClientSession | None = None

    def _client(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()
        return self._session

    async def close(self) -> None:
        if self._session is not None:
            await self._session.close()

    async def _post(self, path: str, payload: dict[str, Any] | None, seconds: float) -> dict[str, Any] | None:
        async with self._client().post(
            f"{self.url}{path}", json=payload, headers=self.headers, timeout=aiohttp.ClientTimeout(total=seconds)
        ) as r:
            if r.status == 200:
                data = await r.json(content_type=None)
                return data if isinstance(data, dict) else {}
            text = (await r.text(errors="replace"))[:200]
            log.warning("Parent answered %s %s: %s", path, r.status, text)
            return None

    async def register(self, proxy_port: int, socks_port: int, public_ip: str | None) -> dict[str, Any] | None:
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
            data = await self._post("/api/worker-nodes/agent/register", payload, 15)
        except Exception as exc:
            log.error("Cannot reach parent: %s", exc)
            return None
        if data is not None:
            log.info("Registered with parent as '%s' (id: %s)", data.get("name"), data.get("node_id"))
        return data

    async def heartbeat(self, proxy: ProxyHandler, proxy_port: int) -> dict[str, Any] | None:
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
            return await self._post("/api/worker-nodes/agent/heartbeat", payload, 10)
        except Exception as exc:
            log.warning("Heartbeat error: %s", exc or type(exc).__name__)
            return None

    async def disconnect(self) -> None:
        try:
            await self._post("/api/worker-nodes/agent/disconnect", None, 5)
            log.info("Notified parent of disconnect")
        except Exception as exc:
            log.debug("Disconnect notice failed: %s", exc)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def heartbeat_interval(value: Any, default: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return max(MIN_HEARTBEAT_INTERVAL, min(MAX_HEARTBEAT_INTERVAL, value))


async def handle_heartbeat_result(result: dict[str, Any], proxy: ProxyHandler) -> None:
    """Act on a heartbeat response: allowlist updates, disabled notice, upgrade request."""
    if not result.get("is_active", True):
        log.warning("Parent has disabled this minion")
    proxy.allowlist.add_all(result.get("server_ips"), "heartbeat")
    latest = result.get("latest_agent_version")
    if is_newer_version(latest):
        log.warning("New agent version available: %s (current: %s)", latest, VERSION)
        if result.get("upgrade_requested") is True:
            log.info("Parent requested upgrade — starting auto-upgrade")
            await proxy.upgrade()


async def heartbeat_loop(parent: ParentClient, proxy: ProxyHandler, port: int, interval: int) -> None:
    while True:
        await asyncio.sleep(interval)
        try:
            result = await parent.heartbeat(proxy, port)
            if result is not None:
                interval = heartbeat_interval(result.get("heartbeat_interval_seconds"), interval)
                await handle_heartbeat_result(result, proxy)
        except Exception:
            log.exception("Heartbeat handling failed")


async def _wait(stop: asyncio.Event, seconds: float) -> bool:
    """Sleep, waking early if stop is set. True if it was."""
    with contextlib.suppress(*TIMEOUT_ERRORS):
        await asyncio.wait_for(stop.wait(), seconds)
    return stop.is_set()


async def run() -> int:
    try:
        cfg = load_config()
    except ConfigError as exc:
        log.error("%s", exc)
        return 1

    log.info("Ghostwire Minion v%s", VERSION)
    log.info("Parent: %s", redact_url(cfg.server_url))
    log.info("Proxy port: %d, SOCKS5 port: %d", cfg.proxy_port, cfg.socks_port)

    stop = asyncio.Event()

    def _quit(sig: signal.Signals) -> None:
        log.info("Received %s — shutting down", sig.name)
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _quit, sig)

    allowlist = Allowlist()
    proxy = ProxyHandler(
        cfg.api_key, verify_ssl=cfg.verify_ssl, allowlist=allowlist, max_response_bytes=cfg.max_response_bytes
    )
    proxy.socks_port = cfg.socks_port
    parent = ParentClient(cfg.server_url, cfg.api_key)

    try:
        proxy._public_ip = await get_public_ip()
        if proxy._public_ip:
            log.info("Public IP: %s", proxy._public_ip)
            own = parse_ip(proxy._public_ip)
            if own is not None:
                _SELF_ADDRESSES.add(own)

        # Register, retrying with backoff until the parent answers (or we're told to stop).
        reg: dict[str, Any] | None = None
        attempt = 0
        while reg is None:
            reg = await parent.register(cfg.proxy_port, cfg.socks_port, proxy._public_ip)
            if reg is not None:
                break
            attempt += 1
            wait = min(MAX_REGISTER_BACKOFF, 5 * 2 ** min(attempt - 1, 6))
            log.warning("Registration attempt %d failed; retrying in %ds", attempt, wait)
            if await _wait(stop, wait):
                return 0

        interval = heartbeat_interval(reg.get("heartbeat_interval_seconds"), 30)
        allowlist.add_all(reg.get("server_ips"), "registration")
        if not allowlist:
            log.warning("SOCKS5 allowlist is empty: nobody can use SOCKS5 until the parent authenticates")

        runner = web.AppRunner(build_app(proxy), shutdown_timeout=10)
        await runner.setup()
        socks5 = Socks5Server(proxy, allowlist)
        try:
            # Every interface: the parent connects from outside. Each HTTP request needs the API key;
            # SOCKS5 takes allowlisted source IPs only.
            await web.TCPSite(runner, "0.0.0.0", cfg.proxy_port).start()  # noqa: S104  see above
            log.info("Listening on 0.0.0.0:%d", cfg.proxy_port)
            await socks5.start("0.0.0.0", cfg.socks_port)  # noqa: S104  see above
        except OSError as exc:
            log.error("Can't listen on port %d or %d: %s", cfg.proxy_port, cfg.socks_port, exc)
            await socks5.stop()
            await runner.cleanup()
            return 1

        hb_task = asyncio.create_task(heartbeat_loop(parent, proxy, cfg.proxy_port, interval))
        await stop.wait()

        hb_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await hb_task
        await socks5.stop()
        await runner.cleanup()
        await parent.disconnect()
    finally:
        await parent.close()
    log.info("Minion stopped.")
    return 0


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    with contextlib.suppress(KeyboardInterrupt):
        sys.exit(asyncio.run(run()))


if __name__ == "__main__":
    main()
