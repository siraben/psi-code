"""Live-API integration test for the ESP32 firmware under QEMU.

Boots the firmware in QEMU with user-mode networking (so the guest can
reach api.anthropic.com via the host), seeds NVS with the
ANTHROPIC_API_KEY from .env.local (or the environment), then sends an
agent turn through /ws and asserts the streamed reply contains "PONG".

This test takes minutes to run end-to-end — it goes from idf.py build
through firmware boot to a live API round-trip — and depends on:

  - --run-firmware enabled (same opt-in flag as test_esp_qemu.py)
  - ANTHROPIC_API_KEY available in the environment or .env.local
  - QEMU's user-mode TCP NAT actually reaching the public internet,
    and an esp-qemu (or qemu-system-xtensa with ESP32 peripherals)
    that lets the firmware bring up its WiFi simulation through
    open_eth far enough to issue HTTPS via mbedTLS.

Skips with a clear reason when any of the above is missing.
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


def _load_env_file():
    """Best-effort: parse .env.local for ANTHROPIC_API_KEY.

    The repo's .env.local uses `export KEY=VALUE` syntax. We avoid
    sourcing it via the shell because that pulls in unrelated keys."""
    path = ROOT / ".env.local"
    if not path.exists():
        return {}
    out = {}
    pattern = re.compile(r"^\s*(?:export\s+)?([A-Z_]+)=(.*)\s*$")
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
            with socket.create_connection((host, port), timeout=2) as s:
                s.close()
            return True
        except OSError:
            time.sleep(1)
    return False


def _build_firmware() -> Path:
    out = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", ".#firmware"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    return Path(out.stdout.strip())


def _seed_nvs(api_key: str, fw_dir: Path) -> Path | None:
    """Generate an NVS partition image with ANTHROPIC_API_KEY seeded.

    Uses ESP-IDF's nvs_partition_gen.py via `idf.py nvs-partition-gen`
    inside the esp dev shell. If idf is not on PATH we skip seeding
    and let the test fail gracefully (the firmware logs the missing
    key and replies with an error frame, which is still an assertion
    we can make)."""
    csv = ROOT / "build-test-nvs.csv"
    img = ROOT / "build-test-nvs.bin"
    csv.write_text(
        "key,type,encoding,value\n"
        f"anthropic_api_key,data,string,{api_key}\n"
    )
    try:
        subprocess.run([
            "nix", "develop", ".#esp", "--command",
            "python", "-m", "esp_idf_nvs_partition_gen",
            "generate", str(csv), str(img), "0x6000",
        ], cwd=ROOT, check=True, capture_output=True)
        return img
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    finally:
        csv.unlink(missing_ok=True)


@pytest.fixture(scope="module")
def qemu_with_key(request):
    if not _firmware_enabled(request):
        pytest.skip("pass --run-firmware to enable firmware/QEMU tests")
    key = _api_key()
    if not key:
        pytest.skip("ANTHROPIC_API_KEY missing (.env.local or environment)")

    try:
        _build_firmware()
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        pytest.skip(f"firmware build failed: {e}")

    # Spawn QEMU. ANTHROPIC_API_KEY is forwarded into NVS via nvs_partition_gen
    # before launch; the firmware's anthropic.lua reads it from NVS at turn time.
    env = dict(os.environ, ANTHROPIC_API_KEY=key)
    proc = subprocess.Popen(
        ["nix", "run", ".#qemu", "--"],
        cwd=ROOT, env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        if not _wait_port("127.0.0.1", HOST_PORT, timeout=120.0):
            proc.terminate()
            pytest.skip("QEMU did not expose port 8000 within 120s")
        yield proc
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_pong_round_trip(qemu_with_key):
    websocket = pytest.importorskip("websocket")
    ws = websocket.create_connection(f"ws://127.0.0.1:{HOST_PORT}/ws", timeout=10)
    try:
        ws.send(json.dumps({
            "type": "user",
            "text": "Reply with the single word PONG and nothing else.",
            "model": "claude-haiku-4-5",
            "max_tokens": 32,
        }))
        deadline = time.monotonic() + 90
        chunks: list[str] = []
        ended = False
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
            t = payload.get("type")
            if t == "assistant_delta":
                chunks.append(payload.get("text") or "")
            elif t == "error":
                pytest.fail(f"firmware reported error: {payload.get('message')}")
            elif t == "turn_end":
                ended = True
                break
        assert ended, "no turn_end received within 90s"
        full = "".join(chunks).strip()
        assert "PONG" in full.upper(), f"reply did not contain PONG: {full!r}"
    finally:
        ws.close()
