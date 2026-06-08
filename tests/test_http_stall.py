"""Regression test for the half-open-connection stream hang.

Stands up a TCP server that accepts then goes silent forever, points the
streaming HTTP client at it with a short PSI_HTTP_IDLE_TIMEOUT, and asserts
the idle-stream watchdog aborts with a transport error (status < 0) instead
of hanging.
"""

from __future__ import annotations

import socket
import subprocess
import threading
import time
from pathlib import Path

import pytest

import lua_runner

ROOT = Path(__file__).resolve().parent.parent

# Drive the C streaming client directly: begin a POST, poll to EOF,
# then finish() and report (status, error). On a stall, finish() returns
# status<0 with a curl "Operation too slow" message.
_EVAL = r"""
local url = os.getenv("PSI_TEST_URL")
local h = psi.http_stream_begin(url, {}, "{}")
if h == nil then return "begin_failed" end
while true do
  local _, done = psi.http_stream_poll(h, 200)
  if done then break end
end
local status, err = psi.http_stream_finish(h)
return "status=" .. tostring(status) .. " err=" .. tostring(err)
"""

IDLE_TIMEOUT_SECS = 3


class _StallServer:
    """Accept connections and never reply, until closed."""

    def __init__(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self._stop = threading.Event()
        self._conns: list[socket.socket] = []
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        self._sock.settimeout(0.25)
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            # Hold the connection open but send nothing: a stalled stream.
            self._conns.append(conn)

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2)
        for conn in self._conns:
            try:
                conn.close()
            except OSError:
                pass
        try:
            self._sock.close()
        except OSError:
            pass


def test_stalled_stream_aborts_within_idle_timeout(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    if not binary.exists():
        pytest.fail(
            f"psi binary not found at {binary}; build it or pass --psi",
            pytrace=False,
        )

    server = _StallServer()
    try:
        env = lua_runner.smoke_env(tmp_path)
        env["PSI_HTTP_IDLE_TIMEOUT"] = str(IDLE_TIMEOUT_SECS)
        env["PSI_TEST_URL"] = f"http://127.0.0.1:{server.port}/"

        start = time.monotonic()
        # Safety net: without the idle watchdog psi hangs here and this
        # raises TimeoutExpired.
        result = subprocess.run(
            [str(binary), "--eval", _EVAL],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(ROOT),
            timeout=IDLE_TIMEOUT_SECS + 30,
        )
        elapsed = time.monotonic() - start
    finally:
        server.close()

    assert result.returncode == 0, (
        f"psi exited {result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )
    # The stalled transfer must be reported as a transport failure
    # (status < 0), not a hang and not a bogus success.
    assert "status=-1" in result.stdout, result.stdout
    # And it must happen well inside the watchdog window plus slack,
    # proving the idle timeout — not the subprocess kill — ended it.
    assert elapsed < IDLE_TIMEOUT_SECS + 20, f"took {elapsed:.1f}s"
