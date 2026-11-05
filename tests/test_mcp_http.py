"""Deterministic integration tests for MCP Streamable HTTP."""

from __future__ import annotations

import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import lua_runner


class _McpState:
    def __init__(
        self,
        *,
        stall: bool = False,
        tools_capability: bool = True,
        malformed_initialize: bool = False,
    ) -> None:
        self.stall = stall
        self.tools_capability = tools_capability
        self.malformed_initialize = malformed_initialize
        self.requests: list[dict[str, Any]] = []
        self.initialize_count = 0
        self.expire_first_call = True
        self.lock = threading.Lock()

    @property
    def session_id(self) -> str:
        return f"local-session-{self.initialize_count}"


class _McpServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, state: _McpState) -> None:
        super().__init__(("127.0.0.1", 0), _McpHandler)
        self.state = state


class _McpHandler(BaseHTTPRequestHandler):
    server: _McpServer

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _record(self, body: dict[str, Any] | None) -> None:
        with self.server.state.lock:
            self.server.state.requests.append(
                {
                    "http_method": self.command,
                    "body": body,
                    "accept": self.headers.get("Accept"),
                    "content_type": self.headers.get("Content-Type"),
                    "protocol": self.headers.get("MCP-Protocol-Version"),
                    "session": self.headers.get("MCP-Session-Id"),
                    "test_token": self.headers.get("X-Test-Token"),
                }
            )

    def _json(self, status: int, value: object, *, session: str | None = None) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if session is not None:
            self.send_header("MCP-Session-Id", session)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            pass

    def _sse(self, value: object) -> None:
        data = json.dumps(value, separators=(",", ":"))
        payload = f"event: message\r\ndata: {data}\r\n\r\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        midpoint = len(payload) // 2
        self.wfile.write(payload[:midpoint])
        self.wfile.flush()
        self.wfile.write(payload[midpoint:])

    def _accepted(self) -> None:
        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        self._record(body)
        state = self.server.state

        if state.stall:
            time.sleep(1.0)
            self._json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": body.get("id"),
                    "result": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "stall", "version": "1"},
                    },
                },
            )
            return

        method = body.get("method")
        if method == "initialize":
            assert self.headers.get("MCP-Protocol-Version") is None
            assert self.headers.get("MCP-Session-Id") is None
            assert self.headers.get("X-Test-Token") == "Bearer local-secret"
            with state.lock:
                state.initialize_count += 1
                session_id = state.session_id
            if state.malformed_initialize:
                self._json(
                    200,
                    {"jsonrpc": "2.0", "id": body["id"], "result": 7},
                    session=session_id,
                )
                return
            self._json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": (
                            {"tools": {"listChanged": True}}
                            if state.tools_capability
                            else {}
                        ),
                        "serverInfo": {"name": "local-test", "version": "1"},
                    },
                },
                session=session_id,
            )
            return

        assert self.headers.get("MCP-Protocol-Version") == "2025-11-25"
        assert self.headers.get("MCP-Session-Id") == state.session_id
        assert self.headers.get("Accept") == "application/json, text/event-stream"

        if body.get("id") is None:
            self._accepted()
            return

        if method == "tools/list":
            cursor = (body.get("params") or {}).get("cursor")
            if cursor is None:
                self._json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": body["id"],
                        "result": {
                            "tools": [
                                {
                                    "name": "echo",
                                    "description": "Echo text through the local MCP server.",
                                    "inputSchema": {
                                        "type": "object",
                                        "properties": {"text": {"type": "string"}},
                                        "required": ["text"],
                                    },
                                }
                            ],
                            "nextCursor": "second-page",
                        },
                    },
                )
            else:
                assert cursor == "second-page"
                self._sse(
                    {
                        "jsonrpc": "2.0",
                        "id": body["id"],
                        "result": {
                            "tools": [
                                {
                                    "name": "fail",
                                    "description": "Return an MCP tool-level error.",
                                    "inputSchema": {"type": "object"},
                                }
                            ]
                        },
                    }
                )
            return

        if method == "tools/call" and state.expire_first_call:
            state.expire_first_call = False
            self._json(
                404,
                {"jsonrpc": "2.0", "error": {"code": -32001, "message": "expired"}},
            )
            return

        if method == "tools/call":
            name = body["params"]["name"]
            if name == "echo":
                text = body["params"]["arguments"]["text"]
                self._sse(
                    {
                        "jsonrpc": "2.0",
                        "id": body["id"],
                        "result": {
                            "content": [{"type": "text", "text": f"echo:{text}"}],
                            "structuredContent": {"echo": text},
                        },
                    }
                )
            else:
                assert name == "fail"
                self._json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": body["id"],
                        "result": {
                            "content": [{"type": "text", "text": "remote failure"}],
                            "isError": True,
                        },
                    },
                )
            return

        raise AssertionError(f"unexpected MCP method: {method}")

    def do_DELETE(self) -> None:  # noqa: N802
        self._record(None)
        assert self.headers.get("MCP-Protocol-Version") == "2025-11-25"
        assert self.headers.get("MCP-Session-Id") == self.server.state.session_id
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


class running_server:
    def __init__(self, state: _McpState) -> None:
        self.server = _McpServer(state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> _McpServer:
        self.thread.start()
        return self.server

    def __exit__(self, *_args: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def _run_psi(binary: Path, tmp_path: Path, expression: str, env_extra: dict[str, str]):
    env = lua_runner.smoke_env(tmp_path)
    env.update(env_extra)
    return subprocess.run(
        [str(binary), "--eval", expression],
        capture_output=True,
        text=True,
        env=env,
        cwd=tmp_path,
        timeout=15,
    )


def test_mcp_http_config_discovery_calls_session_recovery_and_close(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    state = _McpState()
    with running_server(state) as server:
        settings_dir = tmp_path / ".psi"
        settings_dir.mkdir()
        (settings_dir / "settings.json").write_text(
            json.dumps(
                {
                    "mcp": {
                        "servers": {
                            "local": {
                                "transport": "http",
                                "url": f"http://127.0.0.1:{server.server_port}/mcp",
                                "timeout_ms": 2000,
                                "tool_prefix": "remote",
                                "headers": {"X-Test-Token": "Bearer ${MCP_TEST_TOKEN}"},
                            }
                        }
                    }
                }
            )
        )
        expression = r"""
local echo = psi.tool_call("remote_echo", {text = "hello"})
local failure = psi.tool_call("remote_fail", {})
local client = psi.mcp.clients()["local"]
local value = psi.json_encode({
  echo = echo,
  failure = failure,
  protocol = client.protocol_version,
  session = client.session_id,
  tool_count = psi.mcp.status()["local"].tools,
})
psi.mcp.close_all()
return value .. "\n" .. tostring(psi.tools.find("remote_echo"))
"""
        result = _run_psi(binary, tmp_path, expression, {"MCP_TEST_TOKEN": "local-secret"})

    assert result.returncode == 0, result.stderr
    encoded, registered_after_close = result.stdout.splitlines()
    value = json.loads(encoded)
    assert registered_after_close == "nil"
    assert value["protocol"] == "2025-11-25"
    assert value["session"] == "local-session-2"
    assert value["tool_count"] == 2
    assert value["echo"]["ok"] is True
    assert value["echo"]["output"] == "echo:hello"
    assert value["echo"]["structuredContent"] == {"echo": "hello"}
    assert value["failure"]["ok"] is False
    assert value["failure"]["error"] == "remote failure"

    methods = [entry["body"] and entry["body"].get("method") for entry in state.requests]
    assert methods == [
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/list",
        "tools/call",
        "initialize",
        "notifications/initialized",
        "tools/call",
        "tools/call",
        None,
    ]
    assert state.requests[-1]["http_method"] == "DELETE"


def test_mcp_http_request_timeout_is_structured(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    state = _McpState(stall=True)
    with running_server(state) as server:
        expression = r"""
local client, config_err = psi.mcp.new_client({
  url = os.getenv("PSI_TEST_MCP_URL"),
  timeout_ms = 75,
})
if client == nil then return config_err.kind end
local ok, err = client:initialize()
return tostring(ok) .. "|" .. tostring(err.kind) .. "|" .. tostring(err.timeout_ms)
"""
        start = time.monotonic()
        result = _run_psi(
            binary,
            tmp_path,
            expression,
            {"PSI_TEST_MCP_URL": f"http://127.0.0.1:{server.server_port}/mcp"},
        )
        elapsed = time.monotonic() - start

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "nil|timeout|75"
    assert elapsed < 1.0


def test_mcp_http_tool_discovery_requires_negotiated_capability(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    state = _McpState(tools_capability=False)
    with running_server(state) as server:
        expression = r"""
local client = assert(psi.mcp.new_client({
  url = os.getenv("PSI_TEST_MCP_URL"),
  headers = { ["X-Test-Token"] = "Bearer local-secret" },
}))
assert(client:initialize())
local tools, err = client:list_tools()
client:close()
return tostring(tools) .. "|" .. tostring(err.kind)
"""
        result = _run_psi(
            binary,
            tmp_path,
            expression,
            {"PSI_TEST_MCP_URL": f"http://127.0.0.1:{server.server_port}/mcp"},
        )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "nil|capability"
    methods = [entry["body"] and entry["body"].get("method") for entry in state.requests]
    assert methods == ["initialize", "notifications/initialized", None]


def test_mcp_http_malformed_initialize_is_structured(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    state = _McpState(malformed_initialize=True)
    with running_server(state) as server:
        expression = r"""
local client = assert(psi.mcp.new_client({
  url = os.getenv("PSI_TEST_MCP_URL"),
  headers = { ["X-Test-Token"] = "Bearer local-secret" },
}))
local ok, err = client:initialize()
return tostring(ok) .. "|" .. tostring(err.kind)
"""
        result = _run_psi(
            binary,
            tmp_path,
            expression,
            {"PSI_TEST_MCP_URL": f"http://127.0.0.1:{server.server_port}/mcp"},
        )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "nil|protocol"


def test_mcp_http_global_abort_is_structured(tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    state = _McpState(stall=True)
    with running_server(state) as server:
        expression = r"""
local client = assert(psi.mcp.new_client({
  url = os.getenv("PSI_TEST_MCP_URL"),
  timeout_ms = 2000,
}))
psi.abort_trigger()
local ok, err = client:initialize()
return tostring(ok) .. "|" .. tostring(err.kind)
"""
        result = _run_psi(
            binary,
            tmp_path,
            expression,
            {"PSI_TEST_MCP_URL": f"http://127.0.0.1:{server.server_port}/mcp"},
        )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "nil|aborted"
