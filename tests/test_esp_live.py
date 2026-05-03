"""Live-API integration test for the ESP32 firmware under QEMU.

Boots the firmware in QEMU with user-mode networking (so the guest
reaches api.anthropic.com via the host), seeds NVS with the API key
from `.env.local`, then sends an agent turn through the embedded
WebSocket and asserts the streamed reply contains "PONG".

The firmware's agent path is now C-native (`src/backend/esp/esp_agent.c`):
no Lua VM is involved during the turn. The flake's `apps.qemu` wrapper
handles NVS seeding and the QEMU command line; this test just kicks
off `nix run .#qemu` and consumes the WebSocket.

End-to-end runtime: ~60s on a warm Nix store (no firmware rebuild),
multi-minute cold. Skipped unless `--run-firmware` is passed and an
API key is reachable.
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HOST_PORT = int(os.environ.get("PSI_QEMU_PORT", "8765"))


def _load_env_file() -> dict[str, str]:
    """Best-effort: parse .env.local for API keys.

    The repo's .env.local uses `export KEY=VALUE` syntax. We avoid
    sourcing it via the shell because that pulls in unrelated keys."""
    path = ROOT / ".env.local"
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    pattern = re.compile(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\s*$")
    for line in path.read_text().splitlines():
        m = pattern.match(line)
        if m:
            out[m.group(1)] = m.group(2).strip("'\"")
    return out


def _api_key() -> str | None:
    if k := os.environ.get("ANTHROPIC_API_KEY"):
        return k
    return _load_env_file().get("ANTHROPIC_API_KEY")


def _firmware_enabled(request) -> bool:
    return bool(request.config.getoption("--run-firmware"))


def _wait_port(host: str, port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                pass
            return True
        except OSError:
            time.sleep(1)
    return False


@pytest.fixture(scope="module")
def qemu_with_key(request):
    """Boot the firmware in QEMU with the Anthropic key seeded into NVS.

    `apps.qemu` reads $ANTHROPIC_API_KEY at launch and runs
    `nvs_partition_gen.py` to write it into the merged flash image
    before starting qemu-system-xtensa, so we just need to forward
    the env var. The fixture skips if QEMU never opens HOST_PORT
    (firmware build failure, slirp networking issue, etc.)."""
    if not _firmware_enabled(request):
        pytest.skip("pass --run-firmware to enable firmware/QEMU tests")
    key = _api_key()
    if not key:
        pytest.skip("ANTHROPIC_API_KEY missing (.env.local or environment)")

    env = dict(os.environ, ANTHROPIC_API_KEY=key)
    proc = subprocess.Popen(
        ["nix", "run", ".#qemu"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        if not _wait_port("127.0.0.1", HOST_PORT, timeout=180.0):
            proc.terminate()
            pytest.skip(f"QEMU did not expose port {HOST_PORT} within 180s")
        yield proc
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def _drive_ws(prompt: str, model: str = "claude-haiku-4-5", max_tokens: int = 64,
              timeout: float = 90.0) -> tuple[str, bool, str | None]:
    """Send one user turn over the firmware's /ws endpoint and collect the
    streamed reply. Returns (full_text, ended, error_message)."""
    websocket = pytest.importorskip("websocket")
    ws = websocket.WebSocket()
    # The C agent's WebSocket text frames are well-formed UTF-8, but Python
    # 3.13's websocket-client is strict about UTF-8 validation across some
    # control bytes Anthropic streams; skip the check, the JSON parser
    # below catches actually-broken frames.
    ws.connect(f"ws://127.0.0.1:{HOST_PORT}/ws", timeout=10,
               skip_utf8_validation=True)
    try:
        ws.send(json.dumps({
            "type": "user",
            "text": prompt,
            "model": model,
            "max_tokens": max_tokens,
        }))
        deadline = time.monotonic() + timeout
        chunks: list[str] = []
        ended = False
        err: str | None = None
        while time.monotonic() < deadline:
            try:
                msg = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as exc:
                err = f"recv failed: {exc!r}"
                break
            if not msg:
                break
            try:
                payload = json.loads(msg)
            except Exception:
                continue
            t = payload.get("type")
            if t == "assistant_delta":
                chunks.append(payload.get("text") or "")
            elif t == "error":
                err = payload.get("message") or "<no message>"
                break
            elif t == "turn_end":
                ended = True
                break
        return "".join(chunks).strip(), ended, err
    finally:
        ws.close()


def _http_get(path: str, timeout: float = 30.0) -> tuple[int, str]:
    """Plain HTTP GET against the firmware. The 30s timeout covers slow
    cold-cache responses on a freshly-booted QEMU (the merged-flash
    bootloader takes ~5s to reach app_main even before psi runs)."""
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", HOST_PORT, timeout=timeout)
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read().decode("utf-8", "replace")
    return resp.status, body


def test_healthz(qemu_with_key):
    """Smoke: the embedded HTTP server is alive and routes."""
    status, body = _http_get("/healthz")
    assert status == 200, f"healthz returned {status}"
    assert json.loads(body).get("ok") is True


def test_index_served(qemu_with_key):
    """The chat SPA is reachable; it's how a user actually drives the agent."""
    status, body = _http_get("/")
    assert status == 200
    assert "<title>psi</title>" in body
    assert "/ws" in body


def test_pong_round_trip(qemu_with_key):
    """End-to-end live agent turn through Anthropic.

    The C agent path streams Claude's reply over /ws as
    assistant_delta frames, then turn_end. The model gets a tightly
    constrained prompt so the assertion is stable."""
    full, ended, err = _drive_ws(
        "Reply with the single word PONG and nothing else.",
        max_tokens=32, timeout=90.0)
    assert err is None, f"firmware reported error: {err}"
    assert ended, f"no turn_end received; got {full!r}"
    assert "PONG" in full.upper(), f"reply did not contain PONG: {full!r}"


def test_two_consecutive_turns(qemu_with_key):
    """The C agent path is reentrant: a fresh WebSocket connection
    after a completed turn must still talk to Anthropic. Catches the
    `g_ws_session in use` failure mode if cleanup ever regresses."""
    for prompt, expect in [
        ("Reply with PING and nothing else.", "PING"),
        ("Reply with PONG and nothing else.", "PONG"),
    ]:
        full, ended, err = _drive_ws(prompt, max_tokens=32, timeout=90.0)
        assert err is None, f"firmware reported error: {err}"
        assert ended, f"no turn_end received; got {full!r}"
        assert expect in full.upper(), f"expected {expect}, got {full!r}"
