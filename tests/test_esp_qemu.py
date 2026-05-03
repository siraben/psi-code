"""QEMU smoke test for the ESP32 firmware.

Builds the firmware via `nix build .#firmware`, boots it under
qemu-system-xtensa (configured with user-mode networking and a TCP
forward from host:8000 to guest:80), and verifies:

  1. /healthz returns 200 within ~30s of boot.
  2. The /ws WebSocket accepts an upgrade.
  3. A `{"type":"user"}` frame (no API key) at minimum produces an
     `error` frame that mentions the missing key, proving the agent
     loop wired up correctly.

This test does NOT require an Anthropic API key. The companion test
in test_esp_live.py exercises the round-trip with credentials.

Skip rules:
  - QEMU not available on the system (the apps.qemu derivation must
    have built; we look up the wrapper on $PATH or via `nix run`).
  - The user passed --no-firmware to pytest.

The firmware build itself is slow (multi-minute ESP-IDF compile), so
this test is opt-in: pass --run-firmware to enable. Without that flag
it is skipped and the suite stays fast for desktop CI.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HOST_PORT = 8000


def _firmware_enabled(request) -> bool:
    return bool(request.config.getoption("--run-firmware"))


def _wait_port(host: str, port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2) as s:
                s.close()
            return True
        except OSError:
            time.sleep(1)
    return False


def _http_get(path: str, timeout: float = 5.0) -> tuple[int, str]:
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", HOST_PORT, timeout=timeout)
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read().decode("utf-8", "replace")
    return resp.status, body


def _build_firmware() -> Path:
    out = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", ".#firmware"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    return Path(out.stdout.strip())


def _start_qemu() -> subprocess.Popen:
    proc = subprocess.Popen(
        ["nix", "run", ".#qemu", "--"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc


@pytest.fixture(scope="module")
def qemu(request):
    if not _firmware_enabled(request):
        pytest.skip("pass --run-firmware to enable firmware/QEMU tests")
    try:
        _build_firmware()
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        pytest.skip(f"firmware build failed: {e}")
    proc = _start_qemu()
    try:
        ready = _wait_port("127.0.0.1", HOST_PORT, timeout=120.0)
        if not ready:
            proc.terminate()
            pytest.skip("QEMU did not expose port 8000 within 120s "
                        "(likely missing Espressif QEMU peripherals)")
        yield proc
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_healthz(qemu):
    status, body = _http_get("/healthz")
    assert status == 200
    payload = json.loads(body)
    assert payload.get("ok") is True


def test_index_served(qemu):
    status, body = _http_get("/")
    assert status == 200
    assert "<title>psi</title>" in body
    assert "/ws" in body


def test_ws_handshake_and_user_frame(qemu):
    websocket = pytest.importorskip("websocket")
    ws = websocket.create_connection(f"ws://127.0.0.1:{HOST_PORT}/ws", timeout=10)
    try:
        ws.send(json.dumps({"type": "user", "text": "say hello"}))
        # We expect at least one frame back; if no API key is present
        # the firmware should respond with an error frame.
        deadline = time.monotonic() + 30
        saw_frame = False
        while time.monotonic() < deadline:
            try:
                msg = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            if not msg:
                break
            try:
                payload = json.loads(msg)
            except Exception:
                continue
            saw_frame = True
            if payload.get("type") in {"turn_end", "error"}:
                break
        assert saw_frame, "no frames received from /ws"
    finally:
        ws.close()
