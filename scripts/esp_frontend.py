#!/usr/bin/env python3
"""ESP32 host frontend dashboard.

Spawns the firmware under qemu-system-xtensa, parses serial stdout
into structured ESP_LOG frames, and serves the chat UI + telemetry
sidebar at http://localhost:9000.

    browser ──ws──> /chat   ──> proxy ──> ws://qemu:8765/ws
    browser ──ws──> /serial ──> qemu stdout fan-out + parsed stats
    browser ──http──> /, static assets

Run directly (`python3 scripts/esp_frontend.py --firmware ...`) or via
`nix run .#esp-frontend`.
"""
from __future__ import annotations

import argparse
import asyncio
import collections
import json
import logging
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Optional

from aiohttp import WSMsgType, web, ClientSession, ClientTimeout

LOG = logging.getLogger("psi.host")

# `I (12345) tag: message` style ESP_LOG lines. The bracketed level
# can be I/W/E/D/V; the timestamp is uptime in ms.
LOG_LINE_RE = re.compile(
    r"^(?P<level>[IWEDV])\s+\((?P<ts>\d+)\)\s+(?P<tag>[^:]+):\s+(?P<msg>.*)$"
)
HEAP_FREE_RE = re.compile(r"free heap[^:]*:\s*(\d+)", re.IGNORECASE)
HEAP_MIN_RE = re.compile(r"min(?:imum)? free heap[^:]*:\s*(\d+)", re.IGNORECASE)
PSRAM_RE = re.compile(r"(?:psram|spiram)[^:]*:\s*(\d+)", re.IGNORECASE)
IP_RE = re.compile(r"got ip[^:]*:\s*(\d+\.\d+\.\d+\.\d+)", re.IGNORECASE)


class SerialHub:
    """Fan-out of QEMU serial frames to /serial WebSocket clients.

    Keeps a small ring buffer of recent lines so a page that loads
    after boot still sees the recent log context. Tracks parsed stats
    so any new client is bootstrapped to current values.
    """

    BACKLOG = 400

    def __init__(self) -> None:
        self.clients: set[web.WebSocketResponse] = set()
        self.backlog: collections.deque[dict] = collections.deque(maxlen=self.BACKLOG)
        self.stats: dict[str, object] = {}
        self.qemu_state: str = "starting"
        self.boot_ts: float = time.monotonic()

    async def add(self, ws: web.WebSocketResponse) -> None:
        self.clients.add(ws)
        # Send current state immediately.
        await self._send(ws, {"type": "qemu_state", "state": self.qemu_state})
        if self.stats:
            await self._send(ws, {"type": "stats", **self.stats})

    def remove(self, ws: web.WebSocketResponse) -> None:
        self.clients.discard(ws)

    async def replay(self, ws: web.WebSocketResponse) -> None:
        for frame in list(self.backlog):
            await self._send(ws, frame)

    async def broadcast(self, frame: dict) -> None:
        if frame.get("type") in {"log", "raw"}:
            self.backlog.append(frame)
        # Snapshot to avoid mutation during iteration.
        for ws in list(self.clients):
            await self._send(ws, frame)

    async def set_qemu_state(self, state: str) -> None:
        self.qemu_state = state
        await self.broadcast({"type": "qemu_state", "state": state})

    async def update_stats(self, **fields) -> None:
        fields["uptime_s"] = time.monotonic() - self.boot_ts
        self.stats.update(fields)
        await self.broadcast({"type": "stats", **fields})

    @staticmethod
    async def _send(ws: web.WebSocketResponse, frame: dict) -> None:
        if ws.closed:
            return
        try:
            await ws.send_json(frame)
        except (ConnectionResetError, RuntimeError):
            pass


def parse_line(line: str) -> dict:
    """Turn one stdout line into a structured frame for the UI."""
    line = line.rstrip("\r\n")
    m = LOG_LINE_RE.match(line)
    if m:
        return {
            "type": "log",
            "level": m.group("level"),
            "tag": m.group("tag").strip(),
            "ts_ms": int(m.group("ts")),
            "message": m.group("msg"),
        }
    return {"type": "raw", "line": line}


async def parse_stats_from_line(hub: SerialHub, frame: dict) -> None:
    """Update telemetry stats whenever a parseable signal flies by.

    We pattern-match on the message body of structured log frames and
    on raw lines alike — esptool's banner, the ESP-IDF heap report, and
    our own ESP_LOGI("psi", "free heap before VM init: %u") all carry
    one of these.
    """
    text = frame.get("message") or frame.get("line") or ""
    m = HEAP_MIN_RE.search(text)
    if m:
        await hub.update_stats(heap_min=int(m.group(1)))
    else:
        m = HEAP_FREE_RE.search(text)
        if m:
            await hub.update_stats(heap_free=int(m.group(1)))
    m = PSRAM_RE.search(text)
    if m:
        await hub.update_stats(psram_free=int(m.group(1)))
    m = IP_RE.search(text)
    if m:
        await hub.update_stats(ip=m.group(1))


# ---------------------------------------------------------------------------
# QEMU subprocess management
# ---------------------------------------------------------------------------

async def gpio_poll_loop(hub: SerialHub, qemu_port: int,
                         interval_s: float = 0.5) -> None:
    """Poll the firmware's /gpio endpoint and broadcast snapshots.

    Stops on 404 (firmware built without PSI_GPIO_INTROSPECTION).
    """
    url = f"http://127.0.0.1:{qemu_port}/gpio"
    backoff = 1.0
    async with ClientSession(timeout=ClientTimeout(total=2.0)) as session:
        while True:
            try:
                async with session.get(url) as resp:
                    if resp.status == 404:
                        # PSI_GPIO_INTROSPECTION=0 (real hardware). Hide
                        # the grid and stop polling — the operator
                        # measures pins with a probe.
                        await hub.broadcast({"type": "gpio_unavailable"})
                        LOG.info("/gpio not exposed; hiding dashboard pin grid")
                        return
                    if resp.status != 200:
                        await asyncio.sleep(backoff)
                        backoff = min(5.0, backoff * 2)
                        continue
                    snap = await resp.json()
                    backoff = 1.0
                    await hub.broadcast({"type": "gpio", **snap})
            except Exception:  # noqa: BLE001
                await asyncio.sleep(backoff)
                backoff = min(5.0, backoff * 2)
                continue
            await asyncio.sleep(interval_s)


async def _read_qemu(proc: asyncio.subprocess.Process, hub: SerialHub) -> None:
    assert proc.stdout is not None
    while True:
        raw = await proc.stdout.readline()
        if not raw:
            break
        try:
            line = raw.decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            continue
        frame = parse_line(line)
        await hub.broadcast(frame)
        await parse_stats_from_line(hub, frame)
    LOG.warning("qemu stdout EOF")


async def _find_nvs_partition_gen() -> Optional[tuple[str, str]]:
    """Locate ESP-IDF's nvs_partition_gen.py and a python that can run
    it. The flake's apps.qemu finds it via $IDF_PATH; mirror that here
    so the host frontend works whether launched via the flake (where
    IDF_PATH is set) or from a plain devShell.
    """
    idf_path = os.environ.get("IDF_PATH")
    candidates: list[Path] = []
    if idf_path:
        candidates.append(Path(idf_path) / "components" / "nvs_flash"
                          / "nvs_partition_generator" / "nvs_partition_gen.py")
    # Fall back to PATH lookup of nvs_partition_gen.py if it's been
    # symlinked into bin (some IDF wrappers do this).
    which = shutil.which("nvs_partition_gen.py")
    if which:
        candidates.append(Path(which))
    for path in candidates:
        if not path.exists():
            continue
        # The script's first line is a #! pointing at the IDF python
        # env that has esp_idf_nvs_partition_gen installed; reuse it.
        first = path.read_text(encoding="utf-8", errors="replace").splitlines()
        if first and first[0].startswith("#!"):
            shebang = first[0][2:].strip().split()
            if shebang and Path(shebang[0]).exists():
                return shebang[0], str(path)
        py = shutil.which("python3") or shutil.which("python")
        if py:
            return py, str(path)
    return None


def _which_qemu() -> str:
    for name in ("qemu-system-xtensa", "qemu-system-xtensa-esp32"):
        path = shutil.which(name)
        if path:
            return path
    return "qemu-system-xtensa"


async def start_qemu(args, hub: SerialHub) -> Optional[asyncio.subprocess.Process]:
    if args.attach:
        # Attach mode: another process already owns QEMU (typically
        # `nix run .#qemu` in another terminal, where the operator
        # wants to see serial in their own window). We skip the spawn,
        # the proxy still talks to the existing port-forward at
        # --qemu-port, and the serial sidebar stays empty — flag this
        # explicitly so the UI doesn't look broken.
        await hub.broadcast({
            "type": "raw",
            "line": f"[attach mode] not spawning qemu; proxying chat to "
                    f"127.0.0.1:{args.qemu_port}. Serial output is in the "
                    f"window that's running `nix run .#qemu`.",
        })
        await hub.set_qemu_state("up")
        return None
    qemu = args.qemu or _which_qemu()
    fw = Path(args.firmware).resolve()
    if not fw.exists():
        raise SystemExit(f"firmware not found: {fw}")

    # Copy the firmware to a writable scratch path: QEMU opens flash
    # read-write so it can persist NVS sectors. The Nix store output is
    # read-only.
    scratch_dir = Path(args.scratch_dir or "/tmp") / f"psi-host-{os.getpid()}"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    flash = scratch_dir / "flash.bin"
    if not flash.exists():
        flash.write_bytes(fw.read_bytes())

    # Seed ANTHROPIC_API_KEY into the NVS partition if present in env.
    # The firmware reads it from NVS at boot and re-exports it as
    # ANTHROPIC_API_KEY for Lua's os.getenv. NVS lives at offset 0x9000
    # for 0x6000 bytes per partitions.csv.
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if api_key:
        nvs_csv = scratch_dir / "nvs.csv"
        nvs_bin = scratch_dir / "nvs.bin"
        nvs_csv.write_text(
            "key,type,encoding,value\n"
            "psi,namespace,,\n"
            f"anthropic_key,data,string,{api_key}\n"
        )
        gen = await _find_nvs_partition_gen()
        if gen:
            python_exe, gen_script = gen
            cmd = [python_exe, gen_script, "generate", str(nvs_csv),
                   str(nvs_bin), "0x6000"]
            res = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE)
            await res.wait()
            if res.returncode == 0 and nvs_bin.exists():
                with open(flash, "r+b") as f:
                    f.seek(0x9000)
                    f.write(nvs_bin.read_bytes())
                LOG.info("seeded NVS with ANTHROPIC_API_KEY (%d bytes)",
                         nvs_bin.stat().st_size)
            else:
                err = (await res.stderr.read()).decode("utf-8", "replace") if res.stderr else ""
                LOG.warning("nvs partition gen failed: %s", err)
        else:
            LOG.warning("nvs_partition_gen.py not found; key not seeded")
    else:
        LOG.info("ANTHROPIC_API_KEY not set; chat will fail when calling Anthropic")

    cmdline = [
        qemu,
        "-nographic",
        "-machine", "esp32",
        "-m", "4M",
        "-drive", f"file={flash},if=mtd,format=raw",
        "-nic", f"user,model=open_eth,hostfwd=tcp::{args.qemu_port}-:80",
    ]
    LOG.info("starting qemu: %s", " ".join(cmdline))
    await hub.set_qemu_state("starting")
    proc = await asyncio.create_subprocess_exec(
        *cmdline,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        stdin=asyncio.subprocess.DEVNULL,
    )
    asyncio.create_task(_read_qemu(proc, hub))
    return proc


# ---------------------------------------------------------------------------
# HTTP routes
# ---------------------------------------------------------------------------


def make_index(args) -> str:
    # We serve the dashboard's host.html as the root page. The chat
    # half re-uses the firmware's chat module verbatim; the dashboard
    # only adds the telemetry sidebar.
    return (Path(args.assets) / "host" / "host.html").read_text(encoding="utf-8")


async def index_handler(request: web.Request) -> web.Response:
    text = request.app["index_html"]
    return web.Response(text=text, content_type="text/html",
                        headers={"Cache-Control": "no-store"})


async def serial_handler(request: web.Request) -> web.WebSocketResponse:
    hub: SerialHub = request.app["hub"]
    ws = web.WebSocketResponse(heartbeat=30.0)
    await ws.prepare(request)
    await hub.add(ws)
    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                m = json.loads(msg.data)
            except ValueError:
                continue
            if m.get("type") == "replay":
                await hub.replay(ws)
    finally:
        hub.remove(ws)
    return ws


async def chat_proxy_handler(request: web.Request) -> web.WebSocketResponse:
    """Bridge browser /chat WS ↔ ESP firmware /ws.

    Two reasons to proxy through the host instead of having the browser
    connect direct to qemu:port:80/ws:
      1. One origin → one CORS / mixed-content story.
      2. Lets the host snoop chat frames into the telemetry sidebar
         later (e.g. show recent tool calls inline) without the
         browser having to send them twice.
    """
    args = request.app["args"]
    upstream_url = f"ws://127.0.0.1:{args.qemu_port}/ws"
    client_ws = web.WebSocketResponse(heartbeat=30.0)
    await client_ws.prepare(request)

    timeout = ClientTimeout(total=None, sock_connect=10.0)
    async with ClientSession(timeout=timeout) as session:
        try:
            async with session.ws_connect(upstream_url, heartbeat=30.0,
                                          max_msg_size=2 ** 20) as upstream:
                await _bridge(client_ws, upstream)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("upstream ws failed: %s", exc)
            await client_ws.send_json({
                "type": "error",
                "message": f"esp not reachable: {exc}"
            })
    return client_ws


async def _bridge(a: web.WebSocketResponse, b) -> None:
    """Pump messages bidirectionally between a server-side WS and a
    client-side WS until either closes.
    """
    async def pump(src, dst, label):
        try:
            async for msg in src:
                if msg.type == WSMsgType.TEXT:
                    await dst.send_str(msg.data)
                elif msg.type == WSMsgType.BINARY:
                    await dst.send_bytes(msg.data)
                elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                    break
        except Exception as exc:  # noqa: BLE001
            LOG.debug("pump %s ended: %s", label, exc)

    t1 = asyncio.create_task(pump(a, b, "browser→esp"))
    t2 = asyncio.create_task(pump(b, a, "esp→browser"))
    done, pending = await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()


# ---------------------------------------------------------------------------
# App wiring
# ---------------------------------------------------------------------------


def build_app(args) -> web.Application:
    app = web.Application()
    app["args"] = args
    app["hub"] = SerialHub()
    app["index_html"] = make_index(args)

    app.router.add_get("/", index_handler)
    app.router.add_get("/serial", serial_handler)
    app.router.add_get("/chat", chat_proxy_handler)
    app.router.add_static("/", path=str(args.assets), show_index=False)
    return app


async def _run(args) -> None:
    app = build_app(args)
    qemu = await start_qemu(args, app["hub"])

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, args.host, args.port)
    await site.start()
    print(f"psi host dashboard: http://{args.host}:{args.port}")

    asyncio.create_task(gpio_poll_loop(app["hub"], args.qemu_port))

    # The QEMU port forwarder takes a moment to bind; the proxy
    # handler tolerates that. Mark up once the qemu process is alive.
    await app["hub"].set_qemu_state("up")

    stop = asyncio.Event()

    def _shutdown(*_: object) -> None:
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except NotImplementedError:
            pass

    try:
        await stop.wait()
    finally:
        if qemu is not None and qemu.returncode is None:
            qemu.terminate()
            try:
                await asyncio.wait_for(qemu.wait(), 5.0)
            except asyncio.TimeoutError:
                qemu.kill()
        await runner.cleanup()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--firmware", default=None,
                    help="Path to psi-firmware.bin (required unless --attach)")
    ap.add_argument("--attach", action="store_true",
                    help="Don't spawn QEMU; assume one is already running "
                         "with hostfwd to --qemu-port. Useful when "
                         "`nix run .#qemu` is already in another terminal.")
    ap.add_argument("--assets", default=str(Path(__file__).resolve().parent.parent / "assets" / "web"),
                    help="Static assets root (defaults to repo's assets/web)")
    ap.add_argument("--qemu", default=os.environ.get("QEMU_BIN"),
                    help="qemu-system-xtensa binary (default: PATH lookup)")
    ap.add_argument("--qemu-port", type=int, default=8765,
                    help="Host port forwarded to QEMU guest :80")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--scratch-dir", default=None,
                    help="Where to copy the writable flash image (default: /tmp)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if not args.attach and not args.firmware:
        ap.error("--firmware is required unless --attach is set")

    logging.basicConfig(
        format="%(asctime)s %(levelname)-5s %(name)s: %(message)s",
        level=logging.DEBUG if args.verbose else logging.INFO,
    )

    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
