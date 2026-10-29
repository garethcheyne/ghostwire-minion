"""Tests for the security-relevant parts of minion.py: authentication, the SOCKS5 allowlist, target
checks (SSRF), request validation, config loading and heartbeat handling.

Async code runs under asyncio.run, so the tests need nothing beyond pytest and aiohttp.
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from yarl import URL

import minion

KEY = "gw-node-test-key-0123456789"


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def allow_loopback(monkeypatch):
    """Treat loopback as public, so tests can use local servers as proxy targets.

    169.254.169.254 (cloud metadata) stays blocked, standing in for an internal target.
    """
    real = minion.is_blocked_ip

    def is_blocked_ip(ip):
        if ip.is_loopback:
            return False
        return real(ip)

    monkeypatch.setattr(minion, "is_blocked_ip", is_blocked_ip)
    monkeypatch.setattr(minion, "_BLOCKED_HOSTNAMES", frozenset())


# ---------------------------------------------------------------------------
# Target checks
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "127.1.2.3",
        "10.1.2.3",
        "172.16.0.1",
        "192.168.1.1",
        "169.254.169.254",  # cloud metadata
        "100.100.100.200",  # Alibaba metadata, CGNAT range
        "0.0.0.0",
        "255.255.255.255",
        "224.0.0.1",
        "::1",
        "::",
        "fe80::1",
        "fd00:ec2::254",  # AWS IPv6 metadata
        "::ffff:127.0.0.1",
        "::ffff:169.254.169.254",
        "64:ff9b::a9fe:a9fe",  # NAT64 to 169.254.169.254
        "2002:7f00:1::1",  # 6to4 for 127.0.0.1
        "ff02::1",
    ],
)
def test_internal_addresses_are_blocked(address):
    assert minion.is_blocked_ip(minion.parse_ip(address))


@pytest.mark.parametrize("address", ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"])
def test_public_addresses_are_allowed(address):
    assert not minion.is_blocked_ip(minion.parse_ip(address))


def test_own_public_ip_is_blocked(monkeypatch):
    monkeypatch.setattr(minion, "_SELF_ADDRESSES", {minion.parse_ip("8.8.4.4")})
    assert minion.is_blocked_ip(minion.parse_ip("8.8.4.4"))


def test_parse_ip_unwraps_brackets_and_mapped_addresses():
    assert str(minion.parse_ip("[::1]")) == "::1"
    assert str(minion.parse_ip("::ffff:1.2.3.4")) == "1.2.3.4"
    assert minion.parse_ip("example.com") is None
    assert minion.parse_ip("") is None
    assert minion.parse_ip(None) is None


@pytest.mark.parametrize(
    "url",
    [
        "http://localhost/",
        "http://LOCALHOST./",
        "http://app.localhost:3000/",
        "http://127.0.0.1:8080/",
        "http://[::1]/",
        "http://169.254.169.254/latest/meta-data/",
        "http://[::ffff:a9fe:a9fe]/",
        "ftp://example.com/",
        "file:///etc/passwd",
    ],
)
def test_url_block_reason_refuses_internal_urls(url):
    assert minion.url_block_reason(URL(url))


def test_url_block_reason_allows_public_urls():
    assert minion.url_block_reason(URL("https://example.com/path?q=1")) is None
    assert minion.url_block_reason(URL("http://8.8.8.8/")) is None


def test_guarded_resolver_refuses_names_that_resolve_internally(monkeypatch):
    async def fake_resolve(self, host, port=0, family=0):
        address = {"evil.example": "169.254.169.254", "good.example": "93.184.216.34"}[host]
        return [{"hostname": host, "host": address, "port": port, "family": 2, "proto": 6, "flags": 0}]

    monkeypatch.setattr(minion.ThreadedResolver, "resolve", fake_resolve)

    async def go():
        resolver = minion.GuardedResolver()
        with pytest.raises(minion.BlockedTargetError):
            await resolver.resolve("evil.example", 80)
        with pytest.raises(minion.BlockedTargetError):
            await resolver.resolve("localhost", 80)
        assert (await resolver.resolve("good.example", 80))[0]["host"] == "93.184.216.34"
        await resolver.close()

    run(go())


def test_guarded_resolver_catches_numeric_hostnames():
    # 2130706433 is 127.0.0.1 written as a number: not an IP literal to ipaddress, but getaddrinfo
    # resolves it, so it must be caught at resolution time.
    async def go():
        resolver = minion.GuardedResolver()
        with pytest.raises(minion.BlockedTargetError):
            await resolver.resolve("2130706433", 80)
        await resolver.close()

    run(go())


def test_socks_target_resolution_fails_closed(monkeypatch):
    async def fake_getaddrinfo(self, host, port, **kwargs):
        return [(2, 1, 6, "", ("93.184.216.34", port)), (2, 1, 6, "", ("10.0.0.5", port))]

    monkeypatch.setattr(asyncio.BaseEventLoop, "getaddrinfo", fake_getaddrinfo)

    async def go():
        with pytest.raises(minion.BlockedTargetError):
            await minion.resolve_socks_target("mixed.example", 443)
        with pytest.raises(minion.BlockedTargetError):
            await minion.resolve_socks_target("169.254.169.254", 80)
        assert await minion.resolve_socks_target("8.8.8.8", 53) == ["8.8.8.8"]

    run(go())


# ---------------------------------------------------------------------------
# /proxy request validation
# ---------------------------------------------------------------------------


def test_parse_proxy_request_defaults():
    req = minion.parse_proxy_request({"url": "https://example.com/"})
    assert req.method == "GET"
    assert req.headers == {}
    assert req.body is None
    assert req.timeout == 30
    assert req.follow_redirects is True


def test_parse_proxy_request_keeps_parent_fields():
    req = minion.parse_proxy_request(
        {
            "url": "https://example.com/login",
            "method": "post",
            "headers": {"Authorization": "Bearer x", "X-Count": 3},
            "body": "a=1",
            "timeout": 10,
            "follow_redirects": False,
        }
    )
    assert req.method == "POST"
    assert req.headers == {"Authorization": "Bearer x", "X-Count": "3"}
    assert req.body == "a=1"
    assert req.timeout == 10
    assert req.follow_redirects is False


def test_parse_proxy_request_strips_brotli_case_insensitively():
    req = minion.parse_proxy_request({"url": "https://e.com/", "headers": {"accept-encoding": "gzip, br, deflate"}})
    assert req.headers["accept-encoding"] == "gzip, deflate"


def test_parse_proxy_request_caps_timeout():
    assert minion.parse_proxy_request({"url": "https://e.com/", "timeout": 99999}).timeout == minion.MAX_PROXY_TIMEOUT


@pytest.mark.parametrize(
    "body",
    [
        [],
        {},
        {"url": ""},
        {"url": 5},
        {"url": "not a url"},
        {"url": "/relative"},
        {"url": "ftp://example.com/"},
        {"url": "https://e.com/" + "a" * 9000},
        {"url": "https://e.com/", "method": "GET /admin"},
        {"url": "https://e.com/", "method": 1},
        {"url": "https://e.com/", "headers": "x"},
        {"url": "https://e.com/", "headers": {"X-A": "1\r\nX-Injected: 1"}},
        {"url": "https://e.com/", "headers": {"Bad Name": "1"}},
        {"url": "https://e.com/", "headers": {"X-A": ["1"]}},
        {"url": "https://e.com/", "headers": {"X-A": True}},
        {"url": "https://e.com/", "body": ["x"]},
        {"url": "https://e.com/", "timeout": -1},
        {"url": "https://e.com/", "timeout": 0},
        {"url": "https://e.com/", "timeout": "10"},
        {"url": "https://e.com/", "timeout": True},
        {"url": "https://e.com/", "timeout": float("nan")},
        {"url": "https://e.com/", "follow_redirects": "yes"},
    ],
)
def test_parse_proxy_request_rejects_bad_input(body):
    with pytest.raises(minion.RequestError):
        minion.parse_proxy_request(body)


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------


def make_proxy(**kwargs) -> minion.ProxyHandler:
    proxy = minion.ProxyHandler(KEY, **kwargs)
    proxy.socks_port = 1081
    return proxy


async def api(proxy: minion.ProxyHandler) -> TestClient:
    client = TestClient(TestServer(minion.build_app(proxy)))
    await client.start_server()
    return client


def test_health_needs_no_key():
    async def go():
        client = await api(make_proxy())
        try:
            r = await client.get("/health")
            assert r.status == 200
            data = await r.json()
            assert data["status"] == "ok"
            assert data["version"] == minion.VERSION
            assert data["socks_port"] == 1081
            assert data["socks_allowed_ips"] == []
        finally:
            await client.close()

    run(go())


@pytest.mark.parametrize("path", ["/proxy", "/destroy", "/upgrade"])
@pytest.mark.parametrize("headers", [{}, {"X-Minion-API-Key": "wrong"}, {"X-Minion-API-Key": KEY[:-1]}])
def test_commands_need_the_api_key(monkeypatch, path, headers):
    called = []
    monkeypatch.setattr(minion, "start_destroy", lambda: called.append("destroy") or True)
    monkeypatch.setattr(minion, "start_upgrade", lambda: called.append("upgrade") or True)

    async def go():
        proxy = make_proxy()
        client = await api(proxy)
        try:
            r = await client.post(path, json={"url": "https://example.com/"}, headers=headers)
            assert r.status == 401
            await asyncio.sleep(1.2)
            assert called == []
            assert len(proxy.allowlist) == 0  # a failed attempt doesn't get onto the SOCKS5 allowlist
        finally:
            await client.close()

    run(go())


def test_unknown_paths_need_the_api_key():
    async def go():
        client = await api(make_proxy())
        try:
            assert (await client.get("/anything")).status == 401
            assert (await client.get("/anything", headers={"X-Minion-API-Key": KEY})).status == 404
        finally:
            await client.close()

    run(go())


def test_authenticated_request_allowlists_the_caller():
    async def go():
        proxy = make_proxy()
        client = await api(proxy)
        try:
            r = await client.post("/proxy", data="not json", headers={"X-Minion-API-Key": KEY})
            assert r.status == 400
            assert proxy.allowlist.allows("127.0.0.1")
        finally:
            await client.close()

    run(go())


@pytest.mark.parametrize(
    ("body", "status"),
    [
        ({"method": "GET"}, 400),
        ({"url": "https://e.com/", "timeout": "x"}, 400),
        ({"url": "http://127.0.0.1:22/"}, 403),
        ({"url": "http://169.254.169.254/latest/meta-data/"}, 403),
        ({"url": "http://localhost:8080/"}, 403),
    ],
)
def test_proxy_rejects_bad_and_internal_requests(body, status):
    async def go():
        proxy = make_proxy()
        client = await api(proxy)
        try:
            r = await client.post("/proxy", json=body, headers={"X-Minion-API-Key": KEY})
            assert r.status == status
            assert "error" in await r.json()
            assert proxy.active_requests == 0
        finally:
            await client.close()

    run(go())


def test_proxy_blocks_names_resolving_internally(monkeypatch):
    async def fake_resolve(self, host, port=0, family=0):
        return [{"hostname": host, "host": "10.0.0.7", "port": port, "family": 2, "proto": 6, "flags": 0}]

    monkeypatch.setattr(minion.ThreadedResolver, "resolve", fake_resolve)

    async def go():
        client = await api(make_proxy())
        try:
            r = await client.post("/proxy", json={"url": "http://internal.example/"}, headers={"X-Minion-API-Key": KEY})
            assert r.status == 403
            assert "blocked" in (await r.json())["error"]
        finally:
            await client.close()

    run(go())


def test_proxy_rate_limit():
    async def go():
        proxy = make_proxy()
        proxy.max_concurrent = 0
        client = await api(proxy)
        try:
            r = await client.post("/proxy", json={"url": "https://e.com/"}, headers={"X-Minion-API-Key": KEY})
            assert r.status == 429
        finally:
            await client.close()

    run(go())


async def target_server(routes: web.RouteTableDef) -> TestServer:
    app = web.Application()
    app.add_routes(routes)
    server = TestServer(app, host="127.0.0.1")
    await server.start_server()
    return server


def test_proxy_relays_a_request(allow_loopback):
    routes = web.RouteTableDef()

    @routes.post("/echo")
    async def echo(request):
        return web.json_response({"body": await request.text(), "ua": request.headers.get("User-Agent")})

    async def go():
        target = await target_server(routes)
        proxy = make_proxy()
        proxy._public_ip = "203.0.113.5"
        client = await api(proxy)
        try:
            r = await client.post(
                "/proxy",
                json={
                    "url": str(target.make_url("/echo")),
                    "method": "POST",
                    "headers": {"User-Agent": "gw-test"},
                    "body": "hello",
                },
                headers={"X-Minion-API-Key": KEY},
            )
            assert r.status == 200
            data = await r.json()
            assert data["status_code"] == 200
            assert json.loads(data["body"]) == {"body": "hello", "ua": "gw-test"}
            assert data["worker_ip"] == "203.0.113.5"
            assert proxy.request_count == 1
            assert proxy.bytes_transferred > 0
        finally:
            await client.close()
            await target.close()

    run(go())


def test_proxy_checks_every_redirect(allow_loopback):
    routes = web.RouteTableDef()
    hits = []

    @routes.get("/to-metadata")
    async def to_metadata(request):
        hits.append("to-metadata")
        raise web.HTTPFound("http://169.254.169.254/latest/meta-data/")

    @routes.get("/to-self")
    async def to_self(request):
        raise web.HTTPFound("/final")

    @routes.get("/final")
    async def final(request):
        return web.Response(text="arrived")

    async def go():
        target = await target_server(routes)
        client = await api(make_proxy())
        try:
            r = await client.post(
                "/proxy", json={"url": str(target.make_url("/to-metadata"))}, headers={"X-Minion-API-Key": KEY}
            )
            assert r.status == 403
            assert hits == ["to-metadata"]

            r = await client.post(
                "/proxy", json={"url": str(target.make_url("/to-self"))}, headers={"X-Minion-API-Key": KEY}
            )
            data = await r.json()
            assert data["status_code"] == 200
            assert data["body"] == "arrived"

            r = await client.post(
                "/proxy",
                json={"url": str(target.make_url("/to-self")), "follow_redirects": False},
                headers={"X-Minion-API-Key": KEY},
            )
            assert (await r.json())["status_code"] == 302
        finally:
            await client.close()
            await target.close()

    run(go())


def test_proxy_drops_authorization_on_cross_origin_redirect(allow_loopback):
    seen = {}
    other_routes = web.RouteTableDef()

    @other_routes.get("/whoami")
    async def whoami(request):
        seen["auth"] = request.headers.get("Authorization")
        return web.Response(text="ok")

    async def go():
        other = await target_server(other_routes)
        routes = web.RouteTableDef()

        @routes.get("/jump")
        async def jump(request):
            raise web.HTTPFound(str(other.make_url("/whoami")))

        target = await target_server(routes)
        client = await api(make_proxy())
        try:
            r = await client.post(
                "/proxy",
                json={"url": str(target.make_url("/jump")), "headers": {"Authorization": "Bearer secret"}},
                headers={"X-Minion-API-Key": KEY},
            )
            assert (await r.json())["status_code"] == 200
            assert seen["auth"] is None
        finally:
            await client.close()
            await target.close()
            await other.close()

    run(go())


def test_proxy_limits_response_size(allow_loopback):
    routes = web.RouteTableDef()

    @routes.get("/big")
    async def big(request):
        return web.Response(body=b"x" * 5000)

    async def go():
        target = await target_server(routes)
        client = await api(make_proxy(max_response_bytes=1000))
        try:
            r = await client.post(
                "/proxy", json={"url": str(target.make_url("/big"))}, headers={"X-Minion-API-Key": KEY}
            )
            assert r.status == 502
            assert "larger than 1000 bytes" in (await r.json())["error"]
        finally:
            await client.close()
            await target.close()

    run(go())


def test_destroy_and_upgrade_run_after_responding(monkeypatch):
    called = []
    monkeypatch.setattr(minion, "start_destroy", lambda: called.append("destroy") or True)
    monkeypatch.setattr(minion, "start_upgrade", lambda: called.append("upgrade") or True)

    async def go():
        client = await api(make_proxy())
        try:
            r = await client.post("/upgrade", headers={"X-Minion-API-Key": KEY})
            assert r.status == 200
            assert (await r.json())["current_version"] == minion.VERSION
            await asyncio.sleep(1.3)
            assert called == ["upgrade"]
            # Only one upgrade or removal at a time.
            r = await client.post("/destroy", headers={"X-Minion-API-Key": KEY})
            assert (await r.json())["status"] == "destroying"
            await asyncio.sleep(1.3)
            assert called == ["upgrade"]
        finally:
            await client.close()

    run(go())


# ---------------------------------------------------------------------------
# SOCKS5
# ---------------------------------------------------------------------------


async def socks_server(allowlist: minion.Allowlist) -> tuple[minion.Socks5Server, int]:
    server = minion.Socks5Server(make_proxy(), allowlist)
    await server.start("127.0.0.1", 0)
    port = server._server.sockets[0].getsockname()[1]
    return server, port


def connect_request(host: str, port: int) -> bytes:
    if minion.parse_ip(host):
        return b"\x05\x01\x00\x01" + bytes(map(int, host.split("."))) + port.to_bytes(2, "big")
    return b"\x05\x01\x00\x03" + bytes([len(host)]) + host.encode() + port.to_bytes(2, "big")


async def closed_without_reply(reader: asyncio.StreamReader) -> bool:
    """The server hung up without a SOCKS5 reply (EOF, or a reset because the greeting went unread)."""
    try:
        return await asyncio.wait_for(reader.read(2), 5) == b""
    except ConnectionResetError:
        return True


def test_socks_empty_allowlist_lets_nobody_in():
    async def go():
        server, port = await socks_server(minion.Allowlist())
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            assert await closed_without_reply(reader)
            writer.close()
        finally:
            await server.stop()

    run(go())


def test_socks_rejects_addresses_not_on_the_allowlist():
    async def go():
        allowlist = minion.Allowlist()
        allowlist.add("203.0.113.9", "test")
        server, port = await socks_server(allowlist)
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            assert await closed_without_reply(reader)
            writer.close()
        finally:
            await server.stop()

    run(go())


async def socks_handshake(port: int, request: bytes, methods: bytes = b"\x00") -> tuple[bytes, bytes]:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(bytes([5, len(methods)]) + methods)
    await writer.drain()
    greeting = await asyncio.wait_for(reader.read(2), 5)
    reply = b""
    if greeting == b"\x05\x00":
        writer.write(request)
        await writer.drain()
        reply = await asyncio.wait_for(reader.read(10), 5)
    writer.close()
    return greeting, reply


def loopback_allowlist() -> minion.Allowlist:
    allowlist = minion.Allowlist()
    allowlist.add("127.0.0.1", "test")
    return allowlist


@pytest.mark.parametrize(
    ("request_bytes", "code"),
    [
        (connect_request("127.0.0.1", 22), 0x02),
        (connect_request("169.254.169.254", 80), 0x02),
        (connect_request("localhost", 80), 0x02),
        (b"\x05\x02\x00\x01\x08\x08\x08\x08\x00\x35", 0x07),  # BIND isn't supported
        (b"\x05\x01\x00\x09", 0x08),  # unknown address type
    ],
)
def test_socks_refuses_internal_targets_and_unsupported_requests(request_bytes, code):
    async def go():
        server, port = await socks_server(loopback_allowlist())
        try:
            greeting, reply = await socks_handshake(port, request_bytes)
            assert greeting == b"\x05\x00"
            assert reply[:2] == bytes([5, code])
        finally:
            await server.stop()

    run(go())


def test_socks_needs_the_no_auth_method():
    async def go():
        server, port = await socks_server(loopback_allowlist())
        try:
            greeting, _ = await socks_handshake(port, b"", methods=b"\x02")
            assert greeting == b"\x05\xff"
        finally:
            await server.stop()

    run(go())


def test_socks_relays_to_an_allowed_target(allow_loopback):
    async def echo(reader, writer):
        writer.write(await reader.read(100))
        await writer.drain()
        writer.close()

    async def go():
        target = await asyncio.start_server(echo, "127.0.0.1", 0)
        target_port = target.sockets[0].getsockname()[1]
        server, port = await socks_server(loopback_allowlist())
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            assert await reader.readexactly(2) == b"\x05\x00"
            writer.write(connect_request("127.0.0.1", target_port))
            await writer.drain()
            assert (await reader.readexactly(10))[:2] == b"\x05\x00"
            writer.write(b"ping")
            await writer.drain()
            assert await asyncio.wait_for(reader.read(100), 5) == b"ping"
            writer.close()
            assert server.proxy.request_count == 1
        finally:
            await server.stop()
            target.close()
            await target.wait_closed()

    run(go())


def test_socks_stop_closes_open_sessions(allow_loopback):
    async def hold(reader, writer):
        await reader.read(100)

    async def go():
        target = await asyncio.start_server(hold, "127.0.0.1", 0)
        target_port = target.sockets[0].getsockname()[1]
        server, port = await socks_server(loopback_allowlist())
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"\x05\x01\x00")
        await reader.readexactly(2)
        writer.write(connect_request("127.0.0.1", target_port))
        await reader.readexactly(10)
        await asyncio.wait_for(server.stop(), 10)
        assert await asyncio.wait_for(reader.read(10), 5) == b""
        writer.close()
        target.close()

    run(go())


# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------


def test_allowlist_validates_and_normalises():
    allowlist = minion.Allowlist()
    assert not allowlist.allows("127.0.0.1")
    assert not allowlist.allows(None)
    assert not allowlist.add("not-an-ip", "test")
    assert not allowlist.add(None, "test")
    assert allowlist.add("203.0.113.7", "test")
    assert not allowlist.add("203.0.113.7", "test")
    assert allowlist.allows("::ffff:203.0.113.7")
    allowlist.add_all(["2001:db8::1", 5, "x"], "test")
    allowlist.add_all("203.0.113.8", "test")  # not a list: ignored
    assert allowlist.as_list() == ["2001:db8::1", "203.0.113.7"]


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


def test_parse_config_defaults():
    cfg = minion.parse_config({"server_url": "https://gw.example.com/", "api_key": KEY})
    assert cfg.server_url == "https://gw.example.com"
    assert cfg.proxy_port == 1080
    assert cfg.socks_port == 1081
    assert cfg.verify_ssl is True
    assert cfg.max_response_bytes == minion.DEFAULT_MAX_RESPONSE_BYTES
    assert KEY not in repr(cfg)


def test_parse_config_socks_follows_proxy_port():
    assert (
        minion.parse_config({"server_url": "https://g.example", "api_key": KEY, "proxy_port": 9000}).socks_port == 9001
    )


@pytest.mark.parametrize(
    "raw",
    [
        [],
        {"api_key": KEY},
        {"server_url": "https://g.example"},
        {"server_url": "ftp://g.example", "api_key": KEY},
        {"server_url": "g.example", "api_key": KEY},
        {"server_url": "https://g.example", "api_key": ""},
        {"server_url": "https://g.example", "api_key": "gw-node-a\nX-Evil: 1"},
        {"server_url": "https://g.example", "api_key": KEY, "proxy_port": "1080"},
        {"server_url": "https://g.example", "api_key": KEY, "proxy_port": True},
        {"server_url": "https://g.example", "api_key": KEY, "proxy_port": 70000},
        {"server_url": "https://g.example", "api_key": KEY, "proxy_port": 65535},  # no room for SOCKS5
        {"server_url": "https://g.example", "api_key": KEY, "socks_port": 1080},
        {"server_url": "https://g.example", "api_key": KEY, "verify_ssl": "false"},
        {"server_url": "https://g.example", "api_key": KEY, "max_response_bytes": 0},
    ],
)
def test_parse_config_rejects_bad_values(raw):
    with pytest.raises(minion.ConfigError):
        minion.parse_config(raw)


def test_load_config_missing_file(tmp_path):
    with pytest.raises(minion.ConfigError, match="not found"):
        minion.load_config(tmp_path / "config.json")


def test_load_config_invalid_json_does_not_echo_the_key(tmp_path):
    path = tmp_path / "config.json"
    path.write_text('{"server_url": "https://g.example", "api_key": "gw-node-SECRET123",, }')
    with pytest.raises(minion.ConfigError) as info:
        minion.load_config(path)
    assert "SECRET123" not in str(info.value)


def test_load_config_warns_about_plain_http_and_open_permissions(tmp_path, caplog):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"server_url": "http://g.example", "api_key": KEY, "verify_ssl": False}))
    if sys.platform != "win32":
        path.chmod(0o644)
    with caplog.at_level(logging.WARNING, logger="ghostwire-minion"):
        cfg = minion.load_config(path)
    assert cfg.verify_ssl is False
    assert "plain http" in caplog.text
    assert "verify_ssl is false" in caplog.text
    if sys.platform != "win32":
        assert "chmod 600" in caplog.text
    assert KEY not in caplog.text


def test_redact_url_hides_credentials_and_query():
    assert minion.redact_url("https://user:pw@gw.example.com:8443/api?token=x#f") == "https://gw.example.com:8443/api"
    assert minion.redact_url("http://[2001:db8::1]/x") == "http://[2001:db8::1]/x"
    assert minion.redact_url("nonsense") == "<invalid url>"


# ---------------------------------------------------------------------------
# Heartbeats and versions
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("latest", "current", "newer"),
    [
        ("2026.10.30.0100", "2026.10.29.2149", True),
        ("2026.10.29.2149", "2026.10.29.2149", False),
        ("2026.9.1.0000", "2026.10.29.2149", False),
        ("2026.04.05.1700", "0.0.0", True),
        ("garbage", "2026.10.29.2149", False),
        (None, "2026.10.29.2149", False),
    ],
)
def test_is_newer_version(latest, current, newer):
    assert minion.is_newer_version(latest, current) is newer


def test_heartbeat_interval_is_clamped():
    assert minion.heartbeat_interval(30, 10) == 30
    assert minion.heartbeat_interval(0, 10) == minion.MIN_HEARTBEAT_INTERVAL
    assert minion.heartbeat_interval(10**9, 10) == minion.MAX_HEARTBEAT_INTERVAL
    assert minion.heartbeat_interval("30", 10) == 10
    assert minion.heartbeat_interval(None, 10) == 10


def test_heartbeat_result_updates_allowlist_and_upgrades_only_when_asked(monkeypatch):
    monkeypatch.setattr(minion, "VERSION", "2026.10.29.2149")
    upgrades = []

    async def go():
        proxy = make_proxy()

        async def fake_upgrade():
            upgrades.append(True)

        proxy.upgrade = fake_upgrade
        await minion.handle_heartbeat_result(
            {"server_ips": ["198.51.100.1", "bogus"], "latest_agent_version": "2026.10.30.0000"}, proxy
        )
        assert proxy.allowlist.as_list() == ["198.51.100.1"]
        assert upgrades == []
        await minion.handle_heartbeat_result(
            {"latest_agent_version": "2026.10.29.2149", "upgrade_requested": True}, proxy
        )
        assert upgrades == []
        await minion.handle_heartbeat_result(
            {"latest_agent_version": "2026.10.30.0000", "upgrade_requested": True}, proxy
        )
        assert upgrades == [True]

    run(go())


# ---------------------------------------------------------------------------
# Upgrade and self-destruct
# ---------------------------------------------------------------------------


def test_upgrade_uses_the_upgrade_script(monkeypatch, tmp_path):
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "upgrade.sh").write_text("#!/bin/bash\n")
    started = []
    monkeypatch.setattr(minion, "INSTALL_DIR", tmp_path)
    monkeypatch.setattr(minion.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(minion, "run_detached", lambda argv, name: started.append(argv) or True)
    assert minion.start_upgrade() is True
    assert started == [["/usr/bin/bash", str(tmp_path / "scripts" / "upgrade.sh"), "--yes"]]


def test_destroy_only_deletes_the_standard_install_folder(monkeypatch, tmp_path):
    started = []
    monkeypatch.setattr(minion, "_systemd_running", lambda: True)
    monkeypatch.setattr(minion, "run_detached", lambda argv, name: started.append(argv) or True)

    monkeypatch.setattr(minion, "INSTALL_DIR", tmp_path)
    assert minion.start_destroy() is True
    assert started[-1][-1] == ""  # not /opt/ghostwire-minion: files are kept

    monkeypatch.setattr(minion, "INSTALL_DIR", minion.DEFAULT_INSTALL_DIR)
    assert minion.start_destroy() is True
    assert started[-1][-2:] == ["ghostwire-minion", "/opt/ghostwire-minion"]
    assert "systemctl disable --now" in started[-1][2]


def test_destroy_without_a_service_manager_does_nothing(monkeypatch):
    monkeypatch.setattr(minion, "_systemd_running", lambda: False)
    monkeypatch.setattr(minion.shutil, "which", lambda name: None)
    monkeypatch.setattr(minion, "run_detached", lambda argv, name: pytest.fail("should not run"))
    assert minion.start_destroy() is False
