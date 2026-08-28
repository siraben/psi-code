#!/usr/bin/env python3
"""psi smoke suite — multi-step / PTY / live tests.

Single-eval Lua tests live in ``tests/lua/`` as declarative ``.lua`` files
loaded by ``tests/test_lua_cases.py``; see ``tests/lua/README.md``. This
module keeps the cases that need PTY drive, multiple ``psi`` invocations
in one test, ``--print`` / ``--repl`` / ``--help`` surface checks, or the
live-agent tests gated on ``ANTHROPIC_API_KEY``.

Usage:
    tests/smoke.py                 # run everything, live included if key set
    tests/smoke.py --filter foo    # only run tests whose name matches
    tests/smoke.py --no-live       # skip live-agent tests even if key set
    tests/smoke.py --psi PATH      # override psi binary location

Exit status: 0 on clean, 1 on any failure.
"""
from __future__ import annotations

import argparse
import contextvars
import http.server
import json
import os
import re
import shlex
import signal
import socketserver
import subprocess
import sys
import threading
import tempfile
import time
from pathlib import Path

import pexpect
import pyte
import pytest

import lua_runner

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PTY_COLS = 80
DEFAULT_PTY_ROWS = 24
_CURRENT_TEST_ENV: contextvars.ContextVar[dict[str, str] | None] = contextvars.ContextVar(
    "CURRENT_TEST_ENV", default=None)

# ---------------------------------------------------------------------------
# Test runner.
# ---------------------------------------------------------------------------

TESTS: list[tuple[str, callable, dict]] = []

def test(name: str, *, live: bool = False):
    """Decorator: register a test function."""
    def wrap(fn):
        TESTS.append((name, fn, {"live": live}))
        return fn
    return wrap

test.__test__ = False

class Fail(Exception):
    """Raised inside a test on assertion failure."""

def assert_contains(haystack: str, needle: str, what: str = "output") -> None:
    if needle not in haystack:
        raise Fail(f"{what} missing {needle!r}\n--- got ---\n{haystack}")

def assert_not_contains(haystack: str, needle: str, what: str = "output") -> None:
    if needle in haystack:
        raise Fail(f"{what} unexpectedly contains {needle!r}\n--- got ---\n{haystack}")

def assert_bytes_contains(haystack: bytes, needle: bytes, what: str = "output") -> None:
    if needle not in haystack:
        raise Fail(f"{what} missing {needle!r}\n--- got ---\n{haystack!r}")

def assert_bytes_not_contains(haystack: bytes, needle: bytes, what: str = "output") -> None:
    if needle in haystack:
        raise Fail(f"{what} unexpectedly contains {needle!r}\n--- got ---\n{haystack!r}")

def assert_regex(haystack: str, pattern: str, what: str = "output") -> None:
    if not re.search(pattern, haystack, re.MULTILINE):
        raise Fail(f"{what} does not match /{pattern}/\n--- got ---\n{haystack}")

def assert_equals(got, want, what: str = "value") -> None:
    if got != want:
        raise Fail(f"{what}: expected {want!r}, got {got!r}")

def assert_true(cond, reason: str) -> None:
    if not cond:
        raise Fail(reason)

def _selected_tests(name_filter: str | None, excludes: list[str]) -> list[tuple[str, callable, dict]]:
    selected = []
    for name, fn, meta in TESTS:
        if name_filter and name_filter not in name:
            continue
        if any(excluded in name for excluded in excludes):
            continue
        selected.append((name, fn, meta))
    return selected

def _smoke_env(tmp: Path) -> dict[str, str]:
    home = tmp / "home"
    config = tmp / "config"
    state = tmp / "state"
    cache = tmp / "cache"
    for path in (home, config, state, cache):
        path.mkdir(parents=True, exist_ok=True)

    env: dict[str, str] = {}
    for key in (
        "PATH",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "TZ",
        "TERM",
        "TMPDIR",
        "SSL_CERT_FILE",
        "NIX_SSL_CERT_FILE",
        "SSH_AUTH_SOCK",
    ):
        value = os.environ.get(key)
        if value:
            env[key] = value

    for key in (
        "ANTHROPIC_API_KEY",
        "PSI_ANTHROPIC_MODEL",
    ):
        value = os.environ.get(key)
        if value:
            env[key] = value

    env.setdefault("PATH", os.defpath)
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("LANG", "C.UTF-8")
    env.setdefault("LC_ALL", "C.UTF-8")
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(config)
    env["XDG_STATE_HOME"] = str(state)
    env["XDG_CACHE_HOME"] = str(cache)
    env["PWD"] = str(ROOT)
    # Tests run non-interactively against fixture checkouts; trust their
    # project-local resources by default. Individual cases override.
    env["PSI_TRUST"] = "always"
    return env

# ---------------------------------------------------------------------------
# Psi helper: thin wrapper around subprocess that knows where the binary
# lives, keeps a per-test temp dir, and surfaces stdout + stderr + exit.
# ---------------------------------------------------------------------------

class Psi:
    def __init__(self, binary: str, tmp: Path, env: dict[str, str] | None = None):
        self.binary = str(Path(binary).resolve())
        self.tmp = tmp
        self.env = env if env is not None else _smoke_env(tmp)

    def run(self, *args: str, input_text: str | None = None,
            check: bool = True, env_extra: dict | None = None,
            cwd: Path | None = None, timeout: float = 60) -> subprocess.CompletedProcess:
        """Run psi and return the completed process. Raises on non-zero when check=True."""
        env = self.env.copy()
        if env_extra:
            for key, value in env_extra.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = str(value)
        env["PWD"] = str(cwd if cwd else ROOT)
        argv = [self.binary] + list(args)
        res = subprocess.run(
            argv,
            input=input_text,
            capture_output=True,
            text=True,
            env=env,
            cwd=str(cwd) if cwd else None,
            timeout=timeout,
        )
        if check and res.returncode != 0:
            raise Fail(
                f"{shlex.join(argv)} exited with {res.returncode}\n"
                f"--- stdout ---\n{res.stdout}\n--- stderr ---\n{res.stderr}"
            )
        return res

    def eval(self, expr: str) -> str:
        return self.run("--eval", expr).stdout.strip()

    def print_(self, text: str, **kw) -> str:
        return self.run("--print", text, **kw).stdout

    def system_prompt(self, cwd: Path | None = None) -> str:
        return self.run("--system-prompt", cwd=cwd).stdout

    def agent(self, prompt: str, model: str, max_tokens: int = 200,
              session: Path | None = None, **kw) -> subprocess.CompletedProcess:
        args = ["--agent", prompt, "--model", model, "--max-tokens", str(max_tokens)]
        if session:
            args = ["--session", str(session)] + args
        return self.run(*args, timeout=120, **kw)

# ---------------------------------------------------------------------------
# PTY driver for TUI tests. Uses pexpect for process control and pyte for a
# terminal-screen projection. Existing callers still get byte-like output for
# raw ANSI checks, plus exit/screen metadata for newer assertions.
# ---------------------------------------------------------------------------

class PtyOutput(bytes):
    def __new__(cls, raw: bytes, screen_text: str, exitstatus: int | None,
                signalstatus: int | None, timed_out: bool):
        obj = bytes.__new__(cls, raw)
        obj.screen_text = screen_text
        obj.exitstatus = exitstatus
        obj.signalstatus = signalstatus
        obj.timed_out = timed_out
        return obj

    def assert_clean_exit(self) -> None:
        if self.timed_out:
            raise Fail("pty child did not exit before cleanup")
        if self.exitstatus != 0:
            raise Fail(f"pty child exit status: {self.exitstatus}, signal: {self.signalstatus}")

def _pty_screen_text(raw: bytes, cols: int, rows: int) -> str:
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)
    stream.feed(raw.decode("utf-8", "replace"))
    return "\n".join(screen.display)

def run_pty(cmd: list[str], scenario: list[tuple[object, float]],
            env_extra: dict | None = None, idle_drain: float = 2.0,
            cwd: Path | None = None, cols: int = DEFAULT_PTY_COLS,
            rows: int = DEFAULT_PTY_ROWS) -> PtyOutput:
    """Drive a pty session with a scripted (input, wait_secs) sequence.

    Reads everything the child writes and returns it as raw bytes. Sends
    each input after waiting its delay, then idle-drains for `idle_drain`
    seconds after the last input so any trailing output is captured.
    """
    fallback_tmp: tempfile.TemporaryDirectory | None = None
    base_env = _CURRENT_TEST_ENV.get()
    if base_env is not None:
        env = base_env.copy()
    else:
        fallback_tmp = tempfile.TemporaryDirectory(prefix="psi-smoke-pty-")
        env = _smoke_env(Path(fallback_tmp.name))
    if env_extra:
        for key, value in env_extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
    env["PWD"] = str(cwd if cwd else ROOT)

    child = pexpect.spawn(
        cmd[0],
        cmd[1:],
        cwd=str(cwd) if cwd else str(ROOT),
        env=env,
        dimensions=(rows, cols),
        encoding=None,
        timeout=0.1,
    )
    buf = bytearray()

    def drain(seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            timeout = max(0.0, min(0.1, deadline - time.monotonic()))
            try:
                chunk = child.read_nonblocking(size=65536, timeout=timeout)
            except pexpect.TIMEOUT:
                continue
            except pexpect.EOF:
                break
            if not chunk:
                break
            buf.extend(chunk)

    timed_out = False
    try:
        for data, delay in scenario:
            drain(delay)
            if callable(data):
                data(child)
            elif data:
                child.send(data)
        drain(idle_drain)
        timed_out = child.isalive()
    finally:
        if child.isalive():
            child.terminate(force=False)
            deadline = time.monotonic() + 1.0
            while child.isalive() and time.monotonic() < deadline:
                drain(0.05)
            if child.isalive():
                child.terminate(force=True)
        child.close(force=False)
        if fallback_tmp is not None:
            fallback_tmp.cleanup()

    raw = bytes(buf)
    return PtyOutput(raw, _pty_screen_text(raw, cols, rows),
                     child.exitstatus, child.signalstatus, timed_out)

def strip_ansi(raw: bytes) -> str:
    text = raw.decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[\d;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b[=>]", "", text)
    text = re.sub(r"\x1b\[\?[\d]+[a-z]", "", text)
    return text

# ---------------------------------------------------------------------------
# Offline tests (no API key required).
#
# Most single-eval cases live in tests/lua/ as declarative .lua files; this
# module keeps the multi-step / PTY / CLI-surface tests that don't fit that
# format.
# ---------------------------------------------------------------------------

@test("mode/tui_rainbow_renders_ansi")
def t_tui_rainbow_renders_ansi(psi: Psi):
    state = psi.tmp / "state-tui-rainbow"
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.8), (b"/rainbow\r", 1.5), (b"/quit\r", 1.0)],
        env_extra={"NO_COLOR": "", "TERM": "xterm-256color", "XDG_STATE_HOME": str(state)},
        idle_drain=1.5,
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"xterm 256 background swatches", "rainbow header did not render in TUI")
    assert_bytes_contains(raw, b"\x1b[38;5;15;48;5;0m000",
                          "rainbow background colors did not render in TUI")
    assert_bytes_contains(raw, b"\x1b[38;5;16;48;5;255m255",
                          "rainbow high background colors did not render in TUI")
    assert_true(b"016" in raw and b"231" in raw, "rainbow swatches did not render in TUI")

@test("mode/tui_default")
def t_tui_default(psi: Psi):
    raw = run_pty(
        [psi.binary],
        [(b"", 0.8), (b"/rainbow\r", 1.5), (b"/quit\r", 1.0)],
        env_extra={"NO_COLOR": "", "TERM": "xterm-256color"},
        idle_drain=1.5,
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"xterm 256 background swatches", "bare psi did not launch TUI")


@test("mode/tui_auth_permission_warning_owned")
def t_tui_auth_permission_warning_owned(psi: Psi):
    project = psi.tmp / "tui-auth-warning"
    project.mkdir()
    auth_file = project / "auth.json"
    auth_file.write_text("{}")
    auth_file.chmod(0o644)

    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.8),
            (b"draft remains intact", 0.8),
            (b"\x15/quit\r", 0.8),
        ],
        cwd=project,
        rows=32,
        env_extra={
            "PSI_AUTH_FILE": "auth.json",
            "PSI_TUI_INLINE_MAX_ROWS": "24",
            "NO_COLOR": "1",
        },
        idle_drain=1.0,
    )
    raw.assert_clean_exit()
    assert_equals(auth_file.stat().st_mode & 0o777, 0o600, "auth mode")
    assert_contains(
        raw.screen_text,
        "psi: warning: auth.json was group/world-readable; permissions tightened to 0600",
        "structured auth warning",
    )
    assert_bytes_contains(raw, b"draft remains intact", "draft was not rendered")
    assert_equals(
        raw.count(b"psi: warning: auth.json was group/world-readable"),
        1,
        "auth warning render count",
    )
    warning_line = next(
        (line for line in raw.screen_text.splitlines() if "psi: warning: auth.json" in line),
        "",
    )
    assert_not_contains(warning_line, "draft remains intact", "warning/input row separation")


@test("mode/tui_extension_stdio_is_quarantined")
def t_tui_extension_stdio_is_quarantined(psi: Psi):
    project = psi.tmp / "tui-noisy-extension"
    extension_dir = project / ".psi" / "extensions"
    extension_dir.mkdir(parents=True)
    (extension_dir / "noisy.lua").write_text(
        "return function(psi)\n"
        "  psi.commands.register('noisy', function()\n"
        "    print('RAW_STDOUT_SENTINEL')\n"
        "    io.stderr:write('RAW_STDERR_SENTINEL\\n')\n"
        "    psi.log('RAW_LOG_SENTINEL')\n"
        "    return psi.records.new_command_action('print', 'noise handled')\n"
        "  end)\n"
        "end\n"
    )
    state = psi.tmp / "tui-noisy-state"
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.8), (b"/noisy\r", 0.8), (b"/quit\r", 0.8)],
        cwd=project,
        env_extra={"XDG_STATE_HOME": str(state), "NO_COLOR": "1"},
        idle_drain=1.0,
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"noise handled", "structured command output")
    assert_bytes_not_contains(raw, b"RAW_STDOUT_SENTINEL", "raw extension stdout leaked")
    assert_bytes_not_contains(raw, b"RAW_STDERR_SENTINEL", "raw extension stderr leaked")
    assert_bytes_not_contains(raw, b"RAW_LOG_SENTINEL", "psi.log leaked")
    debug_log = state / "psi" / "debug.log"
    assert_true(debug_log.exists(), "TUI debug log was not created")
    logged = debug_log.read_text()
    assert_contains(logged, "RAW_STDOUT_SENTINEL", "quarantined stdout")
    assert_contains(logged, "RAW_STDERR_SENTINEL", "quarantined stderr")
    assert_contains(logged, "RAW_LOG_SENTINEL", "quarantined psi.log")
    assert_equals(debug_log.stat().st_mode & 0o777, 0o600, "debug log mode")


@test("mode/tui_chat_auth_permission_warning_owned")
def t_tui_chat_auth_permission_warning_owned(psi: Psi):
    project = psi.tmp / "tui-chat-auth-warning"
    project.mkdir()
    auth_file = project / "auth.json"
    auth_file.write_text("{}")
    auth_file.chmod(0o644)
    raw = run_pty(
        [psi.binary, "--chat"],
        [(b"", 0.8), (b"chat draft intact", 0.8), (b"\x15/quit\r", 0.8)],
        cwd=project,
        rows=32,
        env_extra={"PSI_AUTH_FILE": "auth.json", "NO_COLOR": "1"},
        idle_drain=1.0,
    )
    raw.assert_clean_exit()
    assert_contains(
        raw.screen_text,
        "psi: warning: auth.json was group/world-readable; permissions tightened to 0600",
        "chat structured auth warning",
    )
    assert_bytes_contains(raw, b"chat draft intact", "chat draft was not rendered")


@test("mode/tui_notice_survives_reload")
def t_tui_notice_survives_reload(psi: Psi):
    project = psi.tmp / "tui-reload-notice"
    extension_dir = project / ".psi" / "extensions"
    extension_dir.mkdir(parents=True)
    (extension_dir / "notice.lua").write_text(
        "return function(psi)\n"
        "  psi.commands.register('emit-notice', function()\n"
        "    psi.notice.warn('RELOAD_NOTICE_SENTINEL')\n"
        "    return psi.records.new_command_action('print', 'notice emitted')\n"
        "  end)\n"
        "end\n"
    )
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.8),
            (b"/reload\r", 0.8),
            (b"/emit-notice\r", 0.8),
            (b"/quit\r", 0.8),
        ],
        cwd=project,
        rows=32,
        env_extra={"PSI_TUI_INLINE_MAX_ROWS": "24", "NO_COLOR": "1"},
        idle_drain=1.0,
    )
    raw.assert_clean_exit()
    assert_contains(raw.screen_text, "RELOAD_NOTICE_SENTINEL", "notice after /reload")
    assert_bytes_contains(raw, b"notice emitted", "reloaded command result")


@test("mode/tui_external_editor_releases_and_reanchors")
def t_tui_external_editor_releases_and_reanchors(psi: Psi):
    editor = psi.tmp / "fake-editor"
    editor.write_text(
        "#!/bin/sh\n"
        "printf 'EDITOR_STDOUT_SENTINEL\\n'\n"
        "printf 'EDITOR_STDERR_SENTINEL\\n' >&2\n"
        "printf 'edited prompt' > \"$1\"\n"
    )
    editor.chmod(0o755)
    for args, layout in ((["--tui"], "frame"), (["--chat"], "chat")):
        state = psi.tmp / f"tui-editor-state-{layout}"
        raw = run_pty(
            [psi.binary, *args],
            [
                (b"", 0.8),
                (b"original prompt", 0.5),
                (b"\x07", 1.0),
                (b"\x15/quit\r", 0.8),
            ],
            rows=40,
            env_extra={
                "EDITOR": str(editor),
                "XDG_STATE_HOME": str(state),
                "PSI_TUI_INLINE_MAX_ROWS": "24",
                "NO_COLOR": "1",
            },
            idle_drain=1.0,
        )
        raw.assert_clean_exit()
        assert_bytes_contains(raw, b"EDITOR_STDOUT_SENTINEL", f"{layout} editor stdout boundary")
        assert_bytes_contains(raw, b"EDITOR_STDERR_SENTINEL", f"{layout} editor stderr boundary")
        assert_bytes_contains(raw, b"edited prompt", f"{layout} editor result was not repainted")
        assert_contains(raw.screen_text, "EDITOR_STDOUT_SENTINEL", f"{layout} editor scrollback")
        assert_contains(raw.screen_text, "EDITOR_STDERR_SENTINEL", f"{layout} editor stderr scrollback")
        debug_log = state / "psi" / "debug.log"
        logged = debug_log.read_text() if debug_log.exists() else ""
        assert_not_contains(
            logged, "EDITOR_STDOUT_SENTINEL", f"{layout} editor stdout was quarantined"
        )
        assert_not_contains(
            logged, "EDITOR_STDERR_SENTINEL", f"{layout} editor stderr was quarantined"
        )


@test("mode/tui_suspend_resumes_and_reanchors")
def t_tui_suspend_resumes_and_reanchors(psi: Psi):
    def resume(child: pexpect.spawn) -> None:
        os.kill(child.pid, signal.SIGCONT)

    for args, layout in ((["--tui"], "frame"), (["--chat"], "chat")):
        raw = run_pty(
            [psi.binary, *args],
            [
                (b"", 0.8),
                (b"suspend draft", 0.5),
                (b"\x1a", 0.5),
                (resume, 0.5),
                (b"", 0.8),
                (b"\x15/quit\r", 0.8),
            ],
            rows=32,
            env_extra={"PSI_TUI_INLINE_MAX_ROWS": "24", "NO_COLOR": "1"},
            idle_drain=1.0,
        )
        raw.assert_clean_exit()
        assert_true(
            raw.count(b"suspend draft") >= 2,
            f"{layout} suspend did not repaint the preserved draft",
        )

@test("mode/tui_rainbow_after_normal_insert")
def t_tui_rainbow_after_normal_insert(psi: Psi):
    state = psi.tmp / "state-tui-rainbow-normal"
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.8),
            (b"/vim\r", 0.4),
            (b"\x1b", 0.4),
            (b"i/rainbow\r", 1.5),
            (b"/quit\r", 1.0),
        ],
        env_extra={"NO_COLOR": "", "TERM": "xterm-256color", "XDG_STATE_HOME": str(state)},
        idle_drain=1.5,
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"xterm 256 background swatches",
                          "normal-mode i/rainbow did not render in TUI")
    assert_bytes_contains(raw, b"\x1b[38;5;15;48;5;0m000",
                          "normal-mode i/rainbow background colors did not render in TUI")
    assert_bytes_contains(raw, b"\x1b[38;5;16;48;5;255m255",
                          "normal-mode i/rainbow high background colors did not render in TUI")
    assert_true(b"016" in raw and b"231" in raw,
                "normal-mode i/rainbow swatches did not render in TUI")
    assert_bytes_not_contains(raw, b"i/rainbow", "normal-mode i leaked into the submitted command")


@test("commands/help_includes_prompt_templates")
def t_commands_help_templates(psi: Psi):
    tmpdir = psi.tmp / "help-prompts"
    tmpdir.mkdir(exist_ok=True)
    (tmpdir / "review.md").write_text(
        "---\n"
        "description: Review staged changes\n"
        "argument-hint: [scope]\n"
        "---\n"
        "Review $@.\n"
    )
    out = psi.run(
        "--eval",
        'local pt = require("psi.prompt_templates")\n'
        + 'local c = require("psi.slash_commands")\n'
        + 'pt.load()\n'
        + 'return c.help_text()',
        env_extra={"PSI_PROMPTS_DIR": str(tmpdir)},
    ).stdout.strip()
    assert_contains(out, "prompt templates", "template help section")
    assert_contains(out, "/review [scope]", "template invocation")
    assert_contains(out, "Review staged changes", "template description")


@test("extensions/no_extensions_disables_user_extension_discovery")
def t_no_extensions_disables_user_extension_discovery(psi: Psi):
    project = psi.tmp / "no-extensions-project"
    ext_dir = project / ".psi" / "extensions"
    ext_dir.mkdir(parents=True, exist_ok=True)
    (ext_dir / "marker.lua").write_text(
        "return function()\n"
        "  local path = os.getenv('PSI_EXTENSION_MARKER')\n"
        "  if path and path ~= '' then\n"
        "    local f = io.open(path, 'w')\n"
        "    if f then f:write('loaded'); f:close() end\n"
        "  end\n"
        "end\n"
    )

    enabled_marker = psi.tmp / "extension-enabled-marker"
    disabled_marker = psi.tmp / "extension-disabled-marker"
    reload_marker = psi.tmp / "extension-disabled-reload-marker"
    psi.run("--eval", "return 'ok'", cwd=project, env_extra={"PSI_EXTENSION_MARKER": enabled_marker})
    assert_true(enabled_marker.exists(), "project extension did not load in the default mode")

    psi.run(
        "--no-extensions",
        "--eval",
        "return 'ok'",
        cwd=project,
        env_extra={"PSI_EXTENSION_MARKER": disabled_marker},
    )
    assert_true(not disabled_marker.exists(), "--no-extensions still loaded a project extension")

    psi.run(
        "--no-extensions",
        "--eval",
        'require("psi.slash_commands").handle("/reload"); return "ok"',
        cwd=project,
        env_extra={"PSI_EXTENSION_MARKER": reload_marker},
    )
    assert_true(not reload_marker.exists(), "--no-extensions allowed /reload to load a project extension")


@test("commands/slash_command_suggestions")
def t_commands_slash_command_suggestions(psi: Psi):
    tmpdir = psi.tmp / "suggest-prompts"
    tmpdir.mkdir(exist_ok=True)
    (tmpdir / "draft.md").write_text(
        "---\n"
        "description: Draft a response\n"
        "argument-hint: <topic>\n"
        "---\n"
        "Draft $@.\n"
    )
    out = psi.run(
        "--eval",
        'local pt = require("psi.prompt_templates")\n'
        + 'local c = require("psi.slash_commands")\n'
        + 'pt.load()\n'
        + 'c.register("debug", {\n'
        + '  description = "Debug a problem",\n'
        + '  argument_hint = "<issue>",\n'
        + '  handler = function() return nil end,\n'
        + '})\n'
        + 'local matches = c.command_suggestions("/d")\n'
        + 'local pieces = {}\n'
        + 'for _, item in ipairs(matches) do\n'
        + '  pieces[#pieces + 1] = item.name .. ":" .. tostring(item.source) .. ":" .. tostring(item.argument_hint or "")\n'
        + 'end\n'
        + 'return table.concat(pieces, "|")',
        env_extra={"PSI_PROMPTS_DIR": str(tmpdir)},
    ).stdout.strip()
    assert_contains(out, "debug:extension:<issue>",
                    "extension command suggestion missing")
    assert_contains(out, "draft:prompt:<topic>",
                    "prompt template suggestion missing")


@test("keybindings/hotkeys_and_footer_are_generated")
def t_keybindings_generated(psi: Psi):
    home = psi.tmp / "keybindings-home"
    (home / ".config" / "psi").mkdir(parents=True, exist_ok=True)
    (home / ".config" / "psi" / "keybindings.json").write_text(
        json.dumps({
            "app.interrupt": "ctrl-z",
            "tui.input.newLine": "alt-d",
            "app.redraw": "ctrl-z",
        })
    )
    out = psi.run(
        "--eval",
        'local kb = require("psi.keybindings")\n'
        + 'local hotkeys = kb.hotkeys_text()\n'
        + 'local footer = kb.footer_hint(psi.json_encode({ busy = true }))\n'
        + 'return kb.display("app.interrupt") .. "|"\n'
        + '  .. kb.display("tui.input.newLine") .. "|"\n'
        + '  .. tostring(hotkeys:find("Ctrl%-Z") ~= nil) .. "|"\n'
        + '  .. footer .. "|"\n'
        + '  .. tostring(#kb.conflicts()) .. "|"\n'
        + '  .. tostring(kb.conflicts()[1].key)',
        env_extra={"HOME": str(home)},
    ).stdout.strip()
    assert_contains(out, "Ctrl-Z|Alt-D|true|Enter queue",
                    "generated keybinding help/footer didn't use overrides")
    assert_contains(out, "Ctrl-Z abort", "busy footer should include abort key")
    assert_contains(out, "1|ctrl-z", "keybinding conflict should be reported")


@test("tools/set_active_filters")
def t_set_active(psi: Psi):
    out = psi.eval(
        'local t = require("psi.tools")\n'
        + 'local all = #t.select_specs()\n'
        + 't.set_active({"read", "grep"})\n'
        + 'local narrowed = #t.select_specs()\n'
        + 'local active = table.concat(t.get_active(), ",")\n'
        + 't.set_active(nil)\n'
        + 'local restored = #t.select_specs()\n'
        + 'return string.format("%d|%d|%s|%d", all, narrowed, active, restored)'
    )
    parts = out.strip().split("|")
    assert_true(int(parts[0]) >= 3 and int(parts[1]) == 2,
                f"allowlist didn't narrow: {out!r}")
    assert_true("read" in parts[2] and "grep" in parts[2],
                f"allowlist missing expected tools: {out!r}")
    assert_equals(parts[0], parts[3], "nil didn't restore full set")


@test("session/send_message")
def t_send_message(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'local before = psi.session_message_count()\n'
        + 's.send_message("user", "from extension")\n'
        + 's.send_message("assistant", "hi")\n'
        + 'local ok, err = s.send_message("bogus", "x")\n'
        + 'return psi.session_message_count() - before\n'
        + '  .. "|" .. tostring(ok) .. "|" .. tostring(err)'
    )
    assert_contains(out, "2|false|unsupported role: bogus",
                    f"send_message wrong shape: {out!r}")


@test("render/thinking_delta")
def t_render_thinking(psi: Psi):
    """boot.lua installs a default render hook for the thinking-delta
    event so reasoning-model (Qwen3, DeepSeek-R1, etc.) output is
    visible in REPL / --agent / --print. Without the hook the whole
    thinking stream is swallowed and a turn can look empty. The label
    fires once per turn, not per-delta."""
    out = psi.eval(
        'local r = require("psi.render")\n'
        + 'local a = r.handle_event("thinking-delta", { text = "first " })\n'
        + 'local b = r.handle_event("thinking-delta", { text = "second" })\n'
        + 'r.handle_event("after-turn", {})\n'
        + 'local c = r.handle_event("thinking-delta", { text = "turn2" })\n'
        + '-- strip ANSI for easier assertions\n'
        + 'local function strip(s)\n'
        + '  return (s:gsub("\\27%[[%d;]*m", ""))\n'
        + 'end\n'
        + 'return strip(a) .. "|" .. strip(b) .. "|" .. strip(c)'
    )
    a, b, c = out.strip().split("|")
    assert_contains(a, "thinking: first",
                    "first delta carries the thinking label")
    assert_not_contains(b, "thinking:", f"label must fire only once per turn, got: {b!r}")
    assert_contains(b, "second", "second delta renders text")
    assert_contains(c, "thinking: turn2",
                    "after-turn resets the one-shot label")


@test("diff/generate_numbered_tool_diff")
def t_diff_generate_numbered_tool_diff(psi: Psi):
    out = psi.run(
        "--eval",
        'local d = require("psi.diff")\n'
        + 'local before = table.concat({"one","two","three","four","five","six","seven","eight","nine","ten"}, "\\n")\n'
        + 'local after = before:gsub("five", "FIVE"):gsub("nine", "NINE")\n'
        + 'return d.generate_diff_string(before, after, 1).diff',
    ).stdout.rstrip("\n")
    assert_not_contains(out, "@@", "tool diff should not render unified hunk headers")
    assert_contains(out, "  4 four", "tool diff should include leading numbered context")
    assert_contains(out, "- 5 five", "tool diff should include numbered removed line")
    assert_contains(out, "+ 5 FIVE", "tool diff should include numbered added line")
    assert_contains(out, "   ...", "tool diff should collapse distant unchanged context")
    assert_contains(out, "- 9 nine", "tool diff should include later numbered removed line")
    assert_contains(out, "+ 9 NINE", "tool diff should include later numbered added line")


@test("diff/render_numbered_tool_diff")
def t_diff_render_numbered_tool_diff(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'local rendered = require("psi.tui_components.diff").render_diff("-12 old word\\n+12 new word\\n 13 same\\n   ...")\n'
        + 'return tostring((psi.runtime_info() or {}).ansi ~= false) .. "\\n" .. rendered',
        env_extra={"PSI_ANSI": "1"},
    ).stdout.rstrip("\n")
    ansi_enabled, out = out.split("\n", 1)
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "-12 old word", "renderer should preserve removed line number")
    assert_contains(plain, "+12 new word", "renderer should preserve added line number")
    assert_contains(plain, " 13 same", "renderer should preserve context line number")
    assert_contains(plain, "   ...", "renderer should preserve collapsed context marker")
    if ansi_enabled == "true":
        assert_contains(out, "\x1b[", "numbered diff should still be styled")


@test("markdown/inline_code_no_backticks")
def t_markdown_inline_code_no_backticks(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'return require("psi.markdown").render_line("Use `psi` here")',
        env_extra={"PSI_ANSI": "1"},
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(plain, "Use psi here", "inline code should not render literal backticks")
    assert_contains(out, "\x1b[", "inline code should still be highlighted")


@test("markdown/unmatched_asterisk_literal")
def t_markdown_unmatched_asterisk_literal(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'return require("psi.markdown").render_inline("Use * for globbing")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(plain, "Use * for globbing", "unmatched emphasis markers should stay literal")


@test("markdown/component_multiline_emphasis")
def t_markdown_component_multiline_emphasis(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'local c = require("psi.tui_components.markdown").new({ text = "**bold\\ncontinued** and tail" })\n'
        + 'return tostring((psi.runtime_info() or {}).ansi ~= false) .. "\\n" .. table.concat(c:render(80), "\\n")',
        env_extra={"PSI_ANSI": "1"},
    ).stdout.rstrip("\n")
    ansi_enabled, rendered = out.split("\n", 1)
    out = rendered
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(plain, "bold continued and tail", "paragraph inline spans should cross soft line breaks")
    if ansi_enabled == "true":
        assert_contains(out, "\x1b[1m", "multiline bold should still emit bold styling")


@test("tui_text/grapheme_display_width")
def t_tui_text_grapheme_display_width(psi: Psi):
    out = psi.run(
        "--eval",
        'local t = require("psi.tui_text")\n'
        + 'return tostring(t.visible_width("á")) .. "," .. tostring(t.visible_width("界")) .. "," .. tostring(t.visible_width("👨‍👩‍👧‍👦"))',
    ).stdout.rstrip("\n")
    assert_equals(out, "1,2,2", "display width should handle combining marks, CJK, and ZWJ emoji")


@test("tui_text/unicode17_cell_widths")
def t_tui_text_unicode17_cell_widths(psi: Psi):
    out = psi.eval(
        'local t = require("psi.tui_text")\n'
        + 'return table.concat({\n'
        + '  psi.cell_width(0x41),\n'
        + '  psi.cell_width(0x4E2D),\n'
        + '  psi.cell_width(0x1F600),\n'
        + '  psi.cell_width(0x0301),\n'
        + '  psi.cell_width(0x200D),\n'
        + '  psi.cell_width(0x17000),\n'
        + '  t.visible_width("𗀀"),\n'
        + '}, ",")'
    )
    assert_equals(out, "1,2,2,0,0,2,2", "Unicode 17 cell widths should match host table")


@test("tui_text/c_primitives_match_lua_contract")
def t_tui_text_c_primitives_match_lua_contract(psi: Psi):
    out = psi.run(
        "--eval",
        'local t = require("psi.tui_text")\n'
        + 'local ansi = string.char(27) .. "[1mwide 界 family 👨‍👩‍👧‍👦" .. string.char(27) .. "[0m"\n'
        + 'local wrapped = t.wrap_ansi(ansi .. " tail words", 8)\n'
        + 'return table.concat({\n'
        + '  t.strip_ansi(ansi),\n'
        + '  tostring(t.visible_width(ansi)),\n'
        + '  tostring(t.byte_index_for_width("á界x", 3)),\n'
        + '  tostring(#wrapped),\n'
        + '  t.strip_ansi(table.concat(wrapped, "|")),\n'
        + '}, "\\n")',
    ).stdout.rstrip("\n")
    lines = out.split("\n")
    assert_equals(lines[0], "wide 界 family 👨‍👩‍👧‍👦", "C strip should remove SGR")
    assert_equals(lines[1], "17", "C width should match terminal cell contract")
    assert_equals(lines[2], "6", "C byte index should stop on cluster boundaries")
    assert_equals(lines[3], "4", "C ANSI wrap should emit expected row count")
    assert_contains(lines[4], "wide 界", "wrapped output should preserve text content")
    assert_contains(lines[4], "tail", "wrapped output should include trailing words")


@test("markdown/component_table_rendering")
def t_markdown_component_table_rendering(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "| Verb | Weight |\\n| --- | --- |\\n| read | 1 |\\n| write | 1 |"\n'
        + '})\n'
        + 'return table.concat(c:render(64), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "┌", "markdown table should render a top border")
    assert_contains(plain, "│ Verb", "markdown table should render the header")
    assert_contains(plain, "│ read", "markdown table should render body rows")
    assert_contains(plain, "└", "markdown table should render a bottom border")


@test("markdown/component_table_wraps_cells")
def t_markdown_component_table_wraps_cells(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "| Name | Notes |\\n| --- | --- |\\n| alpha | one two three four five six |"\n'
        + '})\n'
        + 'return table.concat(c:render(28), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "one two", "markdown table should keep wrapped content")
    assert_contains(plain, "three", "markdown table should wrap wide cells onto later lines")


@test("markdown/component_table_escaped_pipe")
def t_markdown_component_table_escaped_pipe(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "| Expr | Meaning |\\n| --- | --- |\\n| `a\\\\|b` | pipe literal |"\n'
        + '})\n'
        + 'return table.concat(c:render(80), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "a|b", "escaped pipes should stay in the table cell")
    assert_contains(plain, "pipe literal", "escaped pipe row should keep following cells")
    assert_true("`" not in plain, "inline code in table cells should not render backticks")


@test("markdown/component_table_stops_before_paragraph")
def t_markdown_component_table_stops_before_paragraph(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "| A | B |\\n| --- | --- |\\nNext paragraph with | character"\n'
        + '})\n'
        + 'return table.concat(c:render(80), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "Next paragraph with | character",
                    "paragraph after table should still render")
    assert_true("│ Next paragraph" not in plain,
                "paragraph with a pipe should not be swallowed as a table row")


@test("markdown/component_table_without_outer_pipes")
def t_markdown_component_table_without_outer_pipes(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "Verb | Weight\\n--- | ---\\nread | 1"\n'
        + '})\n'
        + 'return table.concat(c:render(64), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "│ Verb", "tables without outer pipes should render")
    assert_contains(plain, "│ read", "tables without outer pipes should keep rows")


@test("markdown/component_table_too_narrow_falls_back")
def t_markdown_component_table_too_narrow_falls_back(psi: Psi):
    out = psi.run(
        "--eval",
        'local c = require("psi.tui_components.markdown").new({\n'
        + '  text = "| A | B | C |\\n| --- | --- | --- |\\n| one | two | three |"\n'
        + '})\n'
        + 'return table.concat(c:render(8), "\\n")',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_contains(plain, "| A |", "narrow tables should fall back to raw markdown")
    assert_contains(plain, "| ---", "narrow fallback should include the separator row")
    assert_true("┌" not in plain, "narrow fallback should not render a boxed table")


@test("compaction/snaps_past_orphan_tool_result")
def t_compact_snap(psi: Psi):
    """Regression for the Haiku session failure: do_compact must never
    leave a tool-result as the first kept entry (orphan). Mirrors pi's
    findValidCutPoints which excludes toolResult from valid cut
    points. Without the snap, Anthropic 400s with 'unexpected
    tool_use_id found in tool_result blocks'."""
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + '-- Build: user, asst(toolCall), tool-result, user, asst(toolCall), tool-result\n'
        + 'local records = require("psi.records")\n'
        + 's.append_user("hi")\n'
        + 's.append_assistant("", {\n'
        + '  { type = "tool_use", id = "call-1", name = "bash",\n'
        + '    input = { command = "ls" } }\n'
        + '}, {})\n'
        + 's.append_tool_result("call-1", "bash", "output1", false)\n'
        + 's.append_user("again")\n'
        + 's.append_assistant("", {\n'
        + '  { type = "tool_use", id = "call-2", name = "bash",\n'
        + '    input = { command = "pwd" } }\n'
        + '}, {})\n'
        + 's.append_tool_result("call-2", "bash", "output2", false)\n'
        + '-- keep_recent=1 would cut at index 5 which is the final\n'
        + '-- tool-result — would orphan it. Snap must move boundary\n'
        + '-- forward past the tool-result entries.\n'
        + 's.do_compact(1, "summary text here")\n'
        + 'local msgs = s.messages()\n'
        + '-- After: compaction-summary + whatever the snap decided.\n'
        + 'local first_kept_role = nil\n'
        + 'for _, m in ipairs(msgs) do\n'
        + '  if m.role ~= "compaction-summary" then\n'
        + '    first_kept_role = m.role\n'
        + '    break\n'
        + '  end\n'
        + 'end\n'
        + 'return tostring(first_kept_role)'
    )
    assert_true(out.strip() != "tool-result",
                f"orphan tool-result kept after compaction: {out!r}")


@test("session/native_token_ranges")
def t_session_native_token_ranges(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'local c = require("psi.context")\n'
        + 's.append_user("12345678")\n'
        + 's.append_user("1234")\n'
        + 's.append_user("123456789")\n'
        + 'local full = psi.session_token_estimate_from(1)\n'
        + 'local tail = psi.session_token_estimate_from(3)\n'
        + 'local keep = c.keep_recent_messages(tail)\n'
        + 'return tostring(full) .. "," .. tostring(tail) .. "," .. tostring(keep)'
    )
    full, tail, keep = [int(x) for x in out.strip().split(",")]
    assert_true(full == 9 and tail == 4,
                f"native token ranges should match calibrated pi-style semantics: {out!r}")
    assert_equals(keep, 1, f"expected one recent message for tail budget: {out!r}")


@test("session/native_token_estimate_matches_pi_shapes")
def t_session_native_token_estimate_matches_pi_shapes(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 's.append_assistant("", {\n'
        + '  { type = "text", text = "abcd" },\n'
        + '  { type = "thinking", thinking = "12345678" },\n'
        + '  { type = "tool_use", id = "call-1", name = "bash",\n'
        + '    input = { command = "ls" } },\n'
        + '}, {})\n'
        + 'local tool_body = { message = { role = "toolResult", content = {\n'
        + '  { type = "text", text = "abcd" }, { type = "image" },\n'
        + '} } }\n'
        + 's.append_message({ role = "tool-result", text = "abcd", data = psi.json_encode(tool_body) })\n'
        + 'return tostring(psi.session_token_estimate_from(1)) .. ","\n'
        + '  .. tostring(psi.session_token_estimate_from(2))'
    )
    total, tool_tail = [int(x) for x in out.strip().split(",")]
    assert_true(total == 1337 and tool_tail == 1328,
                f"native estimator should mirror calibrated pi role/content rules: {out!r}")


@test("anthropic/drops_orphan_tool_result")
def t_anthropic_orphan_drop(psi: Psi):
    """build_api_messages must skip tool-result entries whose
    tool_use_id has no matching tool_use in a preceding assistant
    message — e.g. a session loaded from an older psi that compacted
    without the snap. Exactly the Haiku session 71d7999f symptom."""
    out = psi.eval(
        'local a = require("psi.providers.anthropic")\n'
        + 'local prelude = require("psi.prelude")\n'
        + '-- Synthetic session: compaction + orphan tool-result\n'
        + '-- (tool_use never appeared) + user + assistant-text.\n'
        + 'local function msg(role, body)\n'
        + '  return { role = role, text = "", data = psi.json_encode(body) }\n'
        + 'end\n'
        + 'local session = {\n'
        + '  { role = "compaction-summary", text = "old work",\n'
        + '    data = psi.json_encode({ summary = "old work" }) },\n'
        + '  msg("tool-result", { message = {\n'
        + '    role = "toolResult", toolCallId = "toolu_ORPHAN",\n'
        + '    toolName = "bash",\n'
        + '    content = { { type = "text", text = "stale output" } } } }),\n'
        + '  msg("user", { message = { role = "user",\n'
        + '    content = { { type = "text", text = "continue" } } } }),\n'
        + '}\n'
        + 'local wire = a._test.build_api_messages(session)\n'
        + '-- Walk wire and assert no tool_result with id "toolu_ORPHAN".\n'
        + 'local found = false\n'
        + 'for _, m in ipairs(wire) do\n'
        + '  if type(m.content) == "table" then\n'
        + '    for _, b in ipairs(m.content) do\n'
        + '      if type(b) == "table" and b.type == "tool_result"\n'
        + '         and b.tool_use_id == "toolu_ORPHAN" then\n'
        + '        found = true\n'
        + '      end\n'
        + '    end\n'
        + '  end\n'
        + 'end\n'
        + 'return tostring(found) .. "|" .. tostring(#wire)'
    )
    parts = out.strip().split("|")
    assert_equals(parts[0], "false", f"orphan tool_result still in wire: {out!r}")
    # Expected wire: compaction-summary-as-user + the real user msg = 2
    assert_true(int(parts[1]) >= 1, f"expected at least one wire message: {out!r}")


@test("anthropic/strips_surrogates_from_system_prompt")
def t_anthropic_system_prompt_surrogate(psi: Psi):
    """system_as_blocks must strip lone UTF-16 surrogate bytes
    (CESU-8 ED [A0-BF] [80-BF]) from the system prompt before it
    goes on the wire. Anthropic returns HTTP 400 \"str is not valid
    UTF-8: surrogates not allowed\" otherwise. Project-context files
    like AGENTS.md / CLAUDE.md can carry these bytes if a previous
    tool surfaced them."""
    out = psi.eval(
        'local a = require("psi.providers.anthropic")\n'
        # "hi<U+D800>!" with U+D800 encoded as the 3-byte CESU-8
        # sequence ED A0 80 — exactly what Anthropic rejects.
        + 'local raw = "hi\\xED\\xA0\\x80!"\n'
        + 'local blocks = a._test.system_as_blocks(raw)\n'
        + 'local b = blocks[1]\n'
        + 'return tostring(b.type) .. "|" .. b.text .. "|" .. tostring(#b.text)'
    )
    btype, text, blen = out.strip().split("|")
    assert_equals(btype, "text", f"unexpected block type: {out!r}")
    assert_equals(text, "hi!", f"surrogate not stripped: {out!r}")
    assert_equals(blen, "3", f"unexpected length after strip: {out!r}")


@test("session/ensure_default_path")
def t_session_default_path(psi: Psi):
    """Without --session, TUI calls psi.session.ensure_default_path
    which must pick an XDG-style location so autosave has a target.
    Skipping this made every turn show "failed to save session file"
    in the status bar (session 71f5944b symptom)."""
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'local first = s.ensure_default_path()\n'
        + 'local second = s.ensure_default_path()\n'
        + 'return tostring(first == second) .. "|"\n'
        + '       .. tostring(psi.session_path() == first) .. "|"\n'
        + '       .. (first or "<nil>")'
    )
    ok_idem, ok_set, path = out.strip().split("|", 2)
    assert_equals(ok_idem, "true", f"not idempotent: {out!r}")
    assert_equals(ok_set, "true", f"session_path not set: {out!r}")
    assert_contains(path, "/psi/sessions/", f"unexpected path shape: {path!r}")
    assert_true(path.endswith(".jsonl"), f"missing .jsonl: {path!r}")


@test("session/default_path_is_cwd_scoped")
def t_session_default_path_cwd_scoped(psi: Psi):
    project = psi.tmp / "project path"
    project.mkdir()
    state = psi.tmp / "state"
    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + 'local path = s.ensure_default_path()\n'
        + 'return s.encode_session_dir(psi.cwd()) .. "|" .. path',
        cwd=project,
        env_extra={"XDG_STATE_HOME": str(state)},
    ).stdout.strip()
    encoded, sess_path = out.split("|", 1)
    assert encoded.startswith("--") and encoded.endswith("--"), f"bad encoded dir: {encoded!r}"
    assert str(state / "psi" / "sessions") in sess_path, f"bad state root: {sess_path!r}"
    assert f"/{encoded}/" in sess_path, f"default path not cwd scoped: {sess_path!r}"
    assert sess_path.endswith(".jsonl"), f"missing .jsonl: {sess_path!r}"


@test("session/default_path_bounds_long_cwd_component")
def t_session_default_path_bounds_long_cwd_component(psi: Psi):
    project = psi.tmp / "long-cwd"
    for i in range(36):
        project = project / f"segment-{i:02d}"
    project.mkdir(parents=True)
    state = psi.tmp / "state-long-cwd"
    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + 'local path = s.ensure_default_path()\n'
        + 's.append_user("long path save")\n'
        + 'local ok, err = s.save()\n'
        + 'return tostring(ok) .. "|" .. (err or "") .. "|"\n'
        + "  .. s.encode_session_dir(psi.cwd()) .. '|' .. path",
        cwd=project,
        env_extra={"XDG_STATE_HOME": str(state)},
    ).stdout.strip()
    ok, err, encoded, sess_path = out.split("|", 3)
    assert_equals(ok, "true", f"long cwd session save failed: {err}")
    assert len(encoded) <= 184, f"encoded cwd component too long: {len(encoded)}"
    assert f"/{encoded}/" in sess_path, f"default path not cwd scoped: {sess_path!r}"


@test("session/list_sessions_for_cwd")
def t_session_list_sessions_for_cwd(psi: Psi):
    project = psi.tmp / "project-list"
    other = psi.tmp / "other-project"
    project.mkdir()
    other.mkdir()
    state = psi.tmp / "state-list"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "one", cwd=project, env_extra=env)
    psi.run("--resume", "--print", "followup", cwd=project, env_extra=env)
    psi.run("--print", "two", cwd=other, env_extra=env)
    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + 'local xs = s.list_sessions(psi.cwd())\n'
        + 'return tostring(#xs) .. "|" .. (xs[1] and xs[1].cwd or "") .. "|"\n'
        + '  .. (xs[1] and xs[1].first_message or "")',
        cwd=project,
        env_extra=env,
    ).stdout.strip()
    count, cwd_seen, first = out.split("|", 2)
    assert_equals(count, "1", "directory-scoped session count")
    assert_equals(cwd_seen, str(project), "session cwd")
    assert_contains(first, "one", "first message")


@test("session/find_by_id")
def t_session_find_by_id(psi: Psi):
    # `--session <uuid>` (no path, no .jsonl) should resolve to the
    # JSONL file inside this cwd's session dir, matching what the TUI
    # prints as "Resume with: psi --session <uuid>". Both full ids and
    # unique prefixes work.
    project = psi.tmp / "project-find-by-id"
    project.mkdir()
    state = psi.tmp / "state-find-by-id"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "first", cwd=project, env_extra=env)
    sid = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + "local xs = s.list_sessions(psi.cwd())\n"
        + "return xs[1] and xs[1].id or ''",
        cwd=project,
        env_extra=env,
    ).stdout.strip()
    assert_true(len(sid) > 0, "session has an id")
    out = psi.run("--session", sid[:8], "--print", "second",
                  cwd=project, env_extra=env).stdout
    # `--session <prefix>` resolves to the same session the TUI just
    # printed: --print loads it (3 messages: user "first", synthetic
    # assistant reply, new user "second" + assistant) — if the prefix
    # had failed to resolve, --print would have created a fresh session.
    assert_contains(out, "session-messages: 3", "prefix-resume reloaded prior turns")


@test("tui/busy_status")
def t_tui_busy_status(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'return require("psi.tui_status").render_busy_status("working", 2, 4, 5)',
        env_extra={"PSI_ANSI": "1"},
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(
        plain,
        "⠴ working...",
        "busy status renders Pi's stable label and braille frame",
    )
    assert_contains(out, "\x1b[38;2;138;190;183m", "busy spinner uses the accent color")


@test("tui/differential_redraw_uses_changed_rows")
def t_tui_differential_redraw_uses_changed_rows(psi: Psi):
    out = psi.eval(r"""
local d = require("psi.tui_runtime")._debug_redraw_counts("hello\nhi")
return table.concat({
  tostring(d.first_frames),
  tostring(d.second_frames),
  tostring(d.second_writes),
  tostring(d.second_input_draws > 0),
  tostring(d.second_clears),
  tostring(d.stale_clears > 0),
  tostring(d.line_clears),
  tostring(d.draw_rows),
  tostring(d.raw_draws),
  tostring(d.cursor_sets),
  tostring(d.refreshes),
  tostring(d.renderer_full),
  tostring(d.renderer_diff >= 1),
  tostring(d.renderer_last_mode),
  tostring(d.first_line_width)
}, "|")
""")
    assert_equals(out, "1|0|1|false|0|true|1|0|0|0|0|1|true|diff|79",
                  "stable-size redraw uses changed-row diff output")


@test("tui/renderer_cursor_marker")
def t_tui_renderer_cursor_marker(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local lines, cursor = r.extract_cursor({"ab" .. r.cursor_marker() .. "cd", "ef"})
return table.concat({lines[1], lines[2], tostring(cursor.row), tostring(cursor.col)}, "|")
""")
    assert_equals(out, "abcd|ef|1|3", "renderer strips cursor marker and reports position")


@test("tui/renderer_full_redraw_clears_rows")
def t_tui_renderer_full_redraw_clears_rows(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
renderer:render({lines={"abcdef"}, width=10, height=1})
renderer:render({lines={"x"}, width=10, height=1, force_full=true})
psi.tui_write = old_write
return tostring((writes[2] or ""):find("\27[2K", 1, true) ~= nil)
""")
    assert_equals(out, "true", "full redraw should clear rows before shorter lines")


@test("tui/renderer_moves_cursor_without_line_changes")
def t_tui_renderer_moves_cursor_without_line_changes(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
renderer:render({lines={"abc"}, width=10, height=1, cursor={row=1, col=1, visible=true}})
renderer:render({lines={"abc"}, width=10, height=1, cursor={row=1, col=3, visible=true}})
psi.tui_write = old_write
return table.concat({
  renderer.last_mode,
  tostring(#writes),
  tostring((writes[2] or ""):find("\27[3G", 1, true) ~= nil),
  tostring((writes[2] or ""):find("\27[2K", 1, true) == nil)
}, "|")
""")
    assert_equals(out, "diff|2|true|true", "cursor-only redraw should move hardware cursor")


@test("tui/renderer_applies_cursor_marker_and_resets")
def t_tui_renderer_applies_cursor_marker_and_resets(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
r.new():render({lines={"ab" .. r.cursor_marker() .. "cd"}, width=10, height=1, cursor={visible=true}})
psi.tui_write = old_write
local frame = writes[1] or ""
return table.concat({
  tostring(frame:find(r.cursor_marker(), 1, true) == nil),
  tostring(frame:find("\27]8;;\7", 1, true) ~= nil),
  tostring(frame:find("\27[3G", 1, true) ~= nil),
  tostring(frame:find("\27[?25h", 1, true) ~= nil)
}, "|")
""")
    assert_equals(out, "true|true|true|true",
                  "renderer strips marker, appends line reset, and uses marker cursor")


@test("tui/renderer_uses_discrete_dirty_ranges")
def t_tui_renderer_uses_discrete_dirty_ranges(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
renderer:render({lines={"a", "b", "c", "d"}, width=10, height=4})
renderer:render({lines={"x", "b", "y", "d"}, width=10, height=4})
psi.tui_write = old_write
local out = writes[2] or ""
local ranges = renderer.last_changed_ranges
return table.concat({
  renderer.last_mode,
  tostring(#ranges),
  tostring(ranges[1] and ranges[1].first),
  tostring(ranges[1] and ranges[1].last),
  tostring(ranges[2] and ranges[2].first),
  tostring(ranges[2] and ranges[2].last),
  tostring(out:find("\27[2B", 1, true) ~= nil),
  tostring(select(2, out:gsub("\27%[2K", "")) == 2),
  tostring(out:find("\27%[%d+;%d+H") == nil)
}, "|")
""")
    assert_equals(out, "diff|2|1|1|3|3|true|true|true",
                  "renderer should emit discrete dirty row ranges")


@test("tui/renderer_first_paint_is_relative")
def t_tui_renderer_first_paint_is_relative(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
r.new():render({lines={"abc", "def"}, width=10, height=2, top=9, cursor={row=1, col=2, visible=true}})
psi.tui_write = old_write
local frame = writes[1] or ""
return table.concat({
  tostring(frame:find("\27%[%d+;%d+H") == nil),
  tostring(frame:find("\r\27[J", 1, true) ~= nil),
  tostring(frame:find("\r\n", 1, true) ~= nil)
}, "|")
""")
    assert_equals(out, "true|true|true", "first paint should anchor at the current cursor")


@test("tui/renderer_forced_full_preserves_anchor")
def t_tui_renderer_forced_full_preserves_anchor(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_write = psi.tui_write
local writes = {}
psi.tui_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
local frame = {
  lines = {"one", "two", "three"},
  width = 10,
  height = 3,
  cursor = {row=3, col=1, visible=true},
}
renderer:render(frame)
frame.force_full = true
renderer:render(frame)
r.reset(renderer, "external-owner")
frame.force_full = false
renderer:render(frame)
psi.tui_write = old_write
return table.concat({
  tostring((writes[2] or ""):find("\27[2A\r", 1, true) ~= nil),
  tostring((writes[3] or ""):find("\27[2A\r", 1, true) == nil),
  tostring((writes[3] or ""):find("\r\27[J", 1, true) ~= nil)
}, "|")
""")
    assert_equals(
        out,
        "true|true|true",
        "forced repaint should keep the anchor while external reset reanchors",
    )


@test("tui/hardware_cursor_uses_input_marker")
def t_tui_hardware_cursor_uses_input_marker(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_redraw_counts("hello", {show_hardware_cursor=true})\n'
        + 'local marker = require("psi.tui_renderer").cursor_marker()\n'
        + 'return table.concat({\n'
        + '  tostring(d.first_visible),\n'
        + '  tostring(d.first_col),\n'
        + '  tostring((d.first_frame or ""):find(marker, 1, true) == nil)\n'
        + '}, "|")'
    )
    assert_equals(out, "true|9|true", "hardware cursor is positioned from input marker")


@test("tui/show_thinking_config")
def t_tui_show_thinking_config(psi: Psi):
    default_out = psi.eval('return require("psi.tui_status").show_thinking()')
    assert_equals(default_out, "1", "thinking visible by default in TUI")

    project = psi.tmp / "thinking-config-project"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"tui": {"show_thinking": False}})
    )
    out = psi.run(
        "--eval",
        'return require("psi.tui_status").show_thinking()',
        cwd=project,
    ).stdout.strip()
    assert_equals(out, "0", "project setting hides thinking in TUI")


@test("session/list_sessions_includes_preview")
def t_session_list_sessions_includes_preview(psi: Psi):
    project = psi.tmp / "project-preview"
    project.mkdir()
    state = psi.tmp / "state-preview"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "preview user prompt", cwd=project, env_extra=env)
    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + "local xs = s.list_sessions(psi.cwd())\n"
        + "return table.concat(xs[1] and xs[1].preview or {}, '\\n')",
        cwd=project,
        env_extra=env,
    ).stdout.strip()
    assert_contains(out, "You: preview user prompt", "session preview")

@test("session/list_sessions_recency_scans_large_files")
def t_session_list_sessions_recency_scans_large_files(psi: Psi):
    project = psi.tmp / "project-large-recency"
    project.mkdir()
    state = psi.tmp / "state-large-recency"
    env = {"XDG_STATE_HOME": str(state)}
    enc = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'return s.encode_session_dir("' + str(project) + '")'
    )
    sess_dir = state / "psi" / "sessions" / enc
    sess_dir.mkdir(parents=True)

    old_path = sess_dir / "2020-01-01T00-00-00_old.jsonl"
    newer_path = sess_dir / "2020-01-02T00-00-00_newer.jsonl"
    long_path = sess_dir / "2020-01-01T00-00-01_long.jsonl"

    def header(session_id: str, ts: str):
        return {
            "type": "session",
            "version": 3,
            "id": session_id,
            "timestamp": ts,
            "cwd": str(project),
        }

    def msg(entry_id: str, ts: str, text: str, parent: str | None = None):
        entry = {
            "type": "message",
            "id": entry_id,
            "timestamp": ts,
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": text}],
            },
        }
        if parent is not None:
            entry["parentId"] = parent
        return entry

    old_path.write_text(
        json.dumps(header("old", "2020-01-01T00:00:00Z")) + "\n"
        + json.dumps(msg("old-1", "2020-01-01T00:00:01Z", "old")) + "\n"
    )
    newer_path.write_text(
        json.dumps(header("newer", "2020-01-02T00:00:00Z")) + "\n"
        + json.dumps(msg("newer-1", "2020-01-02T00:00:01Z", "newer")) + "\n"
    )
    filler = "x" * 4096
    with long_path.open("w") as f:
        f.write(json.dumps(header("long", "2020-01-01T00:00:00Z")) + "\n")
        parent = None
        for i in range(80):
            entry_id = f"long-{i}"
            f.write(json.dumps(msg(entry_id, "2020-01-01T00:00:01Z", filler, parent)) + "\n")
            parent = entry_id
        f.write(json.dumps(msg("long-last", "2020-01-03T00:00:01Z", "latest", parent)) + "\n")

    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + 'local xs = s.list_sessions(psi.cwd())\n'
        + 'return (xs[1] and xs[1].id or "") .. "|" .. tostring(xs[1] and xs[1].message_count or 0)',
        cwd=project,
        env_extra=env,
    ).stdout.strip()
    assert_equals(out, "long|81", "large session recency uses tail entries")


@test("tui/no_color_diff_frame")
def t_tui_no_color_diff_frame(psi: Psi):
    out = psi.run(
        "--eval",
        'local d = require("psi.tui_runtime")._debug_redraw_counts("hello")\n'
        + 'local frame = d.second_output or ""\n'
        + 'return table.concat({\n'
        + '  tostring(frame:find("48;5;", 1, true) == nil),\n'
        + '  tostring(frame:find("38;5;", 1, true) == nil)\n'
        + '}, "|")',
        env_extra={"NO_COLOR": "1", "TERM": "xterm-256color"},
    ).stdout.strip()
    assert_equals(out, "true|true", "diff renderer respects NO_COLOR")

@test("session/cwd_scoped_dirs_do_not_collide")
def t_session_cwd_scoped_dirs_do_not_collide(psi: Psi):
    root = psi.tmp / "collision"
    hyphen = root / "a-b"
    nested = root / "a" / "b"
    hyphen.mkdir(parents=True)
    nested.mkdir(parents=True)
    state = psi.tmp / "state-collision"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "from hyphen", cwd=hyphen, env_extra=env)
    psi.run("--print", "from nested", cwd=nested, env_extra=env)
    out = psi.run(
        "--eval",
        'local s = require("psi.session_manager")\n'
        + f"local a = {json.dumps(str(hyphen))}\n"
        + f"local b = {json.dumps(str(nested))}\n"
        + "local xs = s.list_sessions(a)\n"
        + "local ys = s.list_sessions(b)\n"
        + "return s.encode_session_dir(a) .. '|' .. s.encode_session_dir(b) .. '|'\n"
        + "  .. tostring(#xs) .. '|' .. (xs[1] and xs[1].first_message or '') .. '|'\n"
        + "  .. tostring(#ys) .. '|' .. (ys[1] and ys[1].first_message or '')",
        cwd=root,
        env_extra=env,
    ).stdout.strip()
    encoded_a, encoded_b, count_a, first_a, count_b, first_b = out.split("|", 5)
    assert encoded_a != encoded_b, f"cwd encodings collide: {encoded_a!r}"
    assert_equals(count_a, "1", "hyphen cwd session count")
    assert_contains(first_a, "from hyphen", "hyphen cwd first message")
    assert_equals(count_b, "1", "nested cwd session count")
    assert_contains(first_b, "from nested", "nested cwd first message")

@test("prompt/system_lists_tools")
def t_system_prompt_tools(psi: Psi):
    out = psi.system_prompt()
    assert_regex(out, r"^Available tools:$", "available-tools heading")
    assert_contains(out, "lua: Inspect or evaluate the embedded Lua runtime",
                    "lua tool description")

@test("prompt/agents_md_picked_up")
def t_agents_md(psi: Psi):
    ctx = psi.tmp / "project"
    ctx.mkdir(exist_ok=True)
    (ctx / "AGENTS.md").write_text("Project rule: keep changes minimal.\n")
    out = psi.system_prompt(cwd=ctx)
    assert_contains(out, "Project rule: keep changes minimal.",
                    "project rule from AGENTS.md")

@test("prompt/no_context_files_short_alias")
def t_no_context_files_short_alias(psi: Psi):
    ctx = psi.tmp / "no-context-short"
    ctx.mkdir(exist_ok=True)
    (ctx / "AGENTS.md").write_text("Project rule: hidden by -nc.\n")
    out = psi.run("-nc", "--system-prompt", cwd=ctx).stdout
    assert_not_contains(out, "hidden by -nc", "-nc should disable context files")

@test("prompt/no_prompt_templates_keeps_explicit")
def t_no_prompt_templates_keeps_explicit(psi: Psi):
    template = psi.tmp / "explicit-template.md"
    template.write_text("Explicit $1\n")
    out = psi.run(
        "-np",
        "--prompt-template",
        str(template),
        "--eval",
        'return tostring(psi.prompt_templates.expand("/explicit-template ok"))',
    ).stdout.strip()
    assert_equals(out, "Explicit ok", "-np should keep explicit --prompt-template")

@test("cli/help_has_tui")
def t_help(psi: Psi):
    out = psi.run("--help").stdout
    assert_contains(out, "--tui", "--tui in help")
    assert_contains(out, "--repl", "--repl in help")
    assert_contains(out, "--thinking", "--thinking in help")
    assert_contains(out, "--resume", "--resume in help")

@test("cli/thinking_validation")
def t_cli_thinking_validation(psi: Psi):
    res = psi.run("--thinking", "sideways", "--eval", "return 1", check=False)
    assert_true(res.returncode != 0, "invalid --thinking should fail")
    assert_contains(res.stderr, "invalid value for --thinking", "invalid thinking error")

@test("mode/print_text")
def t_print_text(psi: Psi):
    out = psi.print_("hello")
    assert_contains(out, "prompt: hello", "print echo")
    assert_contains(out, "session-messages: 1", "session count")

@test("mode/print_without_state_home")
def t_print_without_state_home(psi: Psi):
    res = psi.run(
        "--print",
        "no state",
        env_extra={"XDG_STATE_HOME": "", "HOME": ""},
    )
    assert_contains(res.stdout, "prompt: no state", "print runs without autosave path")
    assert_equals(res.returncode, 0, "print succeeds when autosave is unavailable")

@test("mode/repl_quit")
def t_repl_quit(psi: Psi):
    # `:quit` should cleanly exit the line-editor shell.
    psi.run("--repl", input_text=":quit\n")

@test("mode/repl_btw_ollama_ephemeral")
def t_repl_btw_ollama_ephemeral(psi: Psi):
    requests: list[dict] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            body = self.rfile.read(length).decode("utf-8")
            requests.append(json.loads(body))
            payload = json.dumps({"message": {"content": "side answer"}}).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, _fmt, *_args):
            return

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_address[1]}/"
        session_path = psi.tmp / "repl-btw.jsonl"
        res = psi.run(
            "--session",
            str(session_path),
            "--model",
            "ollama/qwen2.5",
            "--repl",
            input_text="/btw what is visible?\n/quit\n",
            env_extra={"PSI_OLLAMA_BASE_URL": base},
        )
    finally:
        server.shutdown()
        server.server_close()

    assert_contains(res.stdout, "/btw what is visible?", "REPL echoes btw command")
    assert_contains(res.stdout, "side answer", "REPL prints side answer")
    assert_equals(len(requests), 1, "btw should make one provider request")
    assert_equals(requests[0].get("tools"), None, "btw request must not advertise tools")
    joined = json.dumps(requests[0].get("messages", []))
    assert_contains(joined, "(empty transcript)", "empty session marker reaches provider")
    if session_path.exists():
        assert_equals(session_path.read_text(), "", "btw must not persist transcript entries")

@test("mode/tui_quits")
def t_tui_quits(psi: Psi):
    # Drive the TUI through a pty, send /quit, expect a clean exit.
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"/quit\r", 1.0)],
        env_extra={"XDG_STATE_HOME": str(psi.tmp / "state-tui-quits")},
    )
    raw.assert_clean_exit()
    text = strip_ansi(raw)
    # We don't require exact chrome; just confirm the Lua-rendered top
    # bar was painted before accepting /quit.
    assert_true(
        ("repo" in text and "worktree" in text) or "cwd" in text,
        "TUI header should show workspace context",
    )
    assert_contains(text, "Resume with: psi --session", "TUI quit resume command")

@test("mode/tui_resume_picker_previews_session")
def t_tui_resume_picker_previews_session(psi: Psi):
    project = psi.tmp / "resume-picker-preview"
    project.mkdir()
    state = psi.tmp / "state-resume-picker-preview"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "older preview prompt", cwd=project, env_extra=env)
    psi.run("--print", "newer preview prompt", cwd=project, env_extra=env)
    raw = run_pty(
        [psi.binary, "--tui", "--resume"],
        [(b"", 0.8), (b"\x1b", 0.3)],
        env_extra=env,
        cwd=project,
    )
    text = strip_ansi(raw)
    assert_contains(text, "Resume session", "resume picker")
    assert_contains(text, "Preview", "resume picker preview heading")
    assert_contains(text, "preview prompt", "resume picker conversation preview")

@test("mode/tui_slash_resume_opens_picker")
def t_tui_slash_resume_opens_picker(psi: Psi):
    project = psi.tmp / "slash-resume-picker"
    project.mkdir()
    state = psi.tmp / "state-slash-resume-picker"
    env = {"XDG_STATE_HOME": str(state)}
    psi.run("--print", "slash resume preview prompt", cwd=project, env_extra=env)
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"/resume\r", 0.8), (b"\x1b", 0.2), (b"/quit\r", 0.7)],
        env_extra=env,
        cwd=project,
    )
    raw.assert_clean_exit()
    text = strip_ansi(raw)
    assert_contains(text, "Resume session", "/resume picker")
    assert_contains(text, "slash resume preview prompt", "/resume picker preview")

@test("mode/tui_repeated_arrows_do_not_insert_text")
def t_tui_repeated_arrows_do_not_insert_text(psi: Psi):
    # Application-cursor arrows are ESC O A/B. If the decoder leaks the final
    # byte, the prompt becomes "AAAA.../quit" and the TUI will not exit.
    arrows = (b"\x1bOA" * 20) + (b"\x1bOB" * 20)
    raw = run_pty([psi.binary, "--tui"], [(b"", 0.5), (arrows, 0.2), (b"/quit\r", 1.0)])
    raw.assert_clean_exit()


@test("mode/tui_split_arrow_final_byte_does_not_insert_text")
def t_tui_split_arrow_final_byte_does_not_insert_text(psi: Psi):
    # Simulate a delayed final byte from CSI Up. The late "A" should be
    # discarded as terminal input, not inserted before /quit.
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"\x1b[", 0.1), (b"A/quit\r", 1.0)],
    )
    raw.assert_clean_exit()


@test("mode/tui_theme_applies_to_rendered_colors")
def t_tui_theme_applies_to_rendered_colors(psi: Psi):
    project = psi.tmp / "theme-tui-project"
    extdir = psi.tmp / "theme-tui-ext"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    extdir.mkdir(exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"theme": {"name": "hot-accent"}})
    )
    (extdir / "hot.lua").write_text(
        "return function(psi)\n"
        "  psi.theme.register('hot-accent', {\n"
        "    tui = { accent = { fg = 118, bg = -1 } },\n"
        "  })\n"
        "end\n"
    )
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"/quit\r", 1.0)],
        env_extra={
            "NO_COLOR": "",
            "PSI_EXTENSIONS_DIR": str(extdir),
            "TERM": "xterm-256color",
            "XDG_STATE_HOME": str(psi.tmp / "state-tui-theme"),
        },
        idle_drain=1.0,
        cwd=project,
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"38;5;118", "configured TUI accent color did not reach rendered output")

@test("mode/tui_input_box_background")
def t_tui_input_box_background(psi: Psi):
    state = psi.tmp / "state-tui-input-box"
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"/quit\r", 1.0)],
        env_extra={"NO_COLOR": "", "TERM": "xterm-256color", "XDG_STATE_HOME": str(state)},
        idle_drain=1.0,
    )
    raw.assert_clean_exit()
    assert_true(b"\x1b[0;7m" not in raw and b"\x1b[7m" not in raw,
                "input box should not use reverse-video")
    assert_bytes_not_contains(raw, b"\x1b[?1049h",
                              "default TUI should not enter alternate screen")
    assert_bytes_not_contains(raw, b"\x1b[?1000h",
                              "default TUI should not enable mouse capture")
    assert_bytes_not_contains(raw, b"\x1b[?1006h",
                              "default TUI should not enable SGR mouse capture")
    assert_true(b"\x1b[?2026h" in raw and b"\x1b[?2026l" in raw,
                "redraw should use synchronized terminal output")
    assert_bytes_contains(raw, b"\x1b[?25h", "input box should show the hardware cursor")
    assert_bytes_not_contains(raw, b"\x1b[4m", "input box should not render a Lua-owned cursor cell")
    assert_bytes_not_contains(raw, b"\x1b[48;5;238m",
                              "input box should not paint a filled background")
    assert_bytes_contains(raw, b"\x1b[38;2;95;135;255m",
                          "pi-style input border color did not reach rendered output")

@test("mode/tui_bracketed_paste")
def t_tui_bracketed_paste(psi: Psi):
    # pi parity: ESC[200~ ... ESC[201~ lands in the editor as one multi-line
    # buffer; the embedded newlines must not submit per line.
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 1.0),
            (b"\x1b[200~paste alpha\rpaste beta\x1b[201~", 1.0),
            (b"\x03", 0.5),  # ctrl-c: clear the buffer before quitting
            (b"/quit\r", 1.0),
        ],
        env_extra={"XDG_STATE_HOME": str(psi.tmp / "state-tui-paste")},
    )
    raw.assert_clean_exit()
    assert_bytes_contains(raw, b"\x1b[?2004h", "TUI should enable bracketed paste")
    assert_bytes_contains(raw, b"\x1b[?2004l", "TUI should disable bracketed paste on exit")
    assert_bytes_contains(raw, b"paste alpha", "first pasted line should reach the editor")
    assert_bytes_contains(raw, b"paste beta", "second pasted line should reach the editor")
    assert_true(
        "ANTHROPIC_API_KEY" not in raw.screen_text,
        "bracketed paste must not submit each line as its own message",
    )


@test("mode/tui_tab_completion")
def t_tui_tab_completion(psi: Psi):
    # Exercise the host key decoder, not a synthetic Lua {key="tab"} event.
    # Tab must complete /he to /help before Left moves the cursor. Enter alone
    # can also accept a painted suggestion, but after Left it submits the
    # existing buffer: /help with a decoded Tab, unknown /he without one.
    raw = run_pty(
        [psi.binary, "--tui"],
        [(b"", 0.5), (b"/he\t\x1b[D\r", 0.75), (b"/quit\r", 1.0)],
        env_extra={"XDG_STATE_HOME": str(psi.tmp / "state-tui-tab-completion")},
    )
    raw.assert_clean_exit()
    assert_bytes_contains(
        raw,
        b"extensions:",
        "physical Tab did not reach slash-command completion",
    )

@test("mode/tui_lf_submit")
def t_tui_lf_submit(psi: Psi):
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.5),
            (b"/quit\n", 1.0),
        ],
        env_extra={"XDG_STATE_HOME": str(psi.tmp / "state-tui-lf-submit")},
    )
    raw.assert_clean_exit()
    text = strip_ansi(raw)
    assert_true(
        ("repo" in text and "worktree" in text) or "cwd" in text,
        "bare LF submits commands and paints workspace context",
    )

@test("mode/tui_multiline_prompt")
def t_tui_multiline_prompt(psi: Psi):
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.5),
            (b"alpha\x1b[27;2;13~bravo\r", 1.0),
            (b"/quit\r", 1.0),
        ],
        env_extra={"XDG_STATE_HOME": str(psi.tmp / "state-tui-multiline")},
    )
    raw.assert_clean_exit()
    text = strip_ansi(raw)
    assert_contains(text, "ANTHROPIC_API_KEY is not set", "multiline input submitted")

@test("session/round_trip")
def t_session_round_trip(psi: Psi):
    sess = psi.tmp / "session.jsonl"
    psi.run("--session", str(sess), "--print", "one")
    out = psi.run("--session", str(sess), "--print", "two").stdout
    assert_contains(out, "session-messages: 3", "session count after 2 prints")
    text = sess.read_text()
    assert_contains(text, '"type":"session"', "session header")
    assert_equals(text.count('"type":"message"'), 4, "message count")
    assert_contains(text, '"text":"two"', "second user text")

# ---------------------------------------------------------------------------
# Live-agent tests — gated on ANTHROPIC_API_KEY.
# ---------------------------------------------------------------------------

def _live_model() -> str:
    return os.environ.get("PSI_ANTHROPIC_MODEL", "claude-haiku-4-5")

@test("live/agent_one_shot", live=True)
def t_live_one_shot(psi: Psi):
    out = psi.agent("Say exactly: psi live agent smoke", model=_live_model(), max_tokens=32).stdout
    assert_contains(out, "psi live agent smoke", "echo reply")

@test("live/tool_call_persists", live=True)
def t_live_tool_call(psi: Psi):
    sess = psi.tmp / "agent.jsonl"
    out = psi.agent(
        "Use the bash tool to run exactly: echo tool-smoke-ok. "
        "Then reply with exactly: tool smoke ok",
        model=_live_model(), max_tokens=200, session=sess,
    ).stdout
    assert_contains(out, "tool smoke ok", "agent reply")
    text = sess.read_text()
    # Session v2: tool_use blocks live inside assistant.content, role is camelCase.
    assert_contains(text, '"type":"toolCall"', "tool_use in assistant content")
    assert_contains(text, '"role":"toolResult"', "toolResult message")

@test("live/second_turn", live=True)
def t_live_second_turn(psi: Psi):
    sess = psi.tmp / "agent.jsonl"
    # Prime with a first turn so we have something to continue.
    psi.agent("Reply with exactly: first turn ok", model=_live_model(),
              max_tokens=32, session=sess)
    out = psi.agent("Reply with exactly: second turn ok", model=_live_model(),
                    max_tokens=64, session=sess).stdout
    assert_contains(out, "second turn ok", "second turn reply")

@test("live/compact", live=True)
def t_live_compact(psi: Psi):
    sess = psi.tmp / "agent.jsonl"
    # Generate some traffic to compact.
    psi.agent("Reply 'a'", model=_live_model(), max_tokens=16, session=sess)
    psi.agent("Reply 'b'", model=_live_model(), max_tokens=16, session=sess)
    psi.agent("Reply 'c'", model=_live_model(), max_tokens=16, session=sess)
    psi.run("--session", str(sess), "--compact", "1",
            "--model", _live_model(), "--max-tokens", "256")
    text = sess.read_text()
    assert_contains(text, '"type":"compaction"', "compaction header entry")

@test("live/concurrent_tools_wall_time", live=True)
def t_live_parallel_walltime(psi: Psi):
    sess = psi.tmp / "parallel.jsonl"
    t0 = time.time()
    psi.agent(
        "Issue three separate bash tool calls in this same turn, all at "
        "once. The three commands are exactly: \"sleep 3 && echo apple\", "
        "\"sleep 6 && echo banana\", \"sleep 9 && echo cherry\". Do not "
        "chain them with &&, do not background them with &, do not combine "
        "them — emit three distinct tool_use blocks. After the tools run, "
        "reply with exactly: parallel done",
        model=_live_model(), max_tokens=500, session=sess,
    )
    elapsed = time.time() - t0
    text = sess.read_text()
    for fruit in ("apple", "banana", "cherry"):
        assert_contains(text, fruit, f"{fruit} in session")
    # Sum-serial would be ~18s; parallel should be ~max (9s) + round trip.
    # 15s upper bound: generous enough for network + compaction, tight
    # enough to catch a silent regression back to serial dispatch.
    assert_true(
        elapsed <= 15.0,
        f"concurrent tools ran serially: elapsed={elapsed:.1f}s (>15s)",
    )
    # Stash for the final summary line.
    t_live_parallel_walltime.elapsed = elapsed  # type: ignore[attr-defined]

@test("live/concurrent_tools_tui_panels", live=True)
def t_live_parallel_panels(psi: Psi):
    """Drive the TUI with the same parallel-tools prompt and confirm each
    tool renders in its own ╭─/│/╰─ panel, not a single blob.
    """
    raw = run_pty(
        [psi.binary, "--tui", "--model", _live_model(), "--max-tokens", "500"],
        [
            (b"", 0.8),
            (
                b"Issue three separate bash tool_use blocks: "
                b"sleep 3 && echo apple ; sleep 6 && echo banana ; "
                b"sleep 9 && echo cherry. Then reply done.\r",
                60.0,
            ),
            (b"\x07", 2.0),
            (b"/quit\r", 2.0),
        ],
        idle_drain=5.0,
    )
    raw.assert_clean_exit()
    text = strip_ansi(raw)
    # Each fruit must appear in the rendered output (progress or final).
    # This is the semantic check: if all three appear, three tools ran
    # in the same turn. The pi-style renderer uses filled tool blocks
    # instead of unicode panel chrome, so assert on the pending block
    # background in the raw capture rather than a border glyph.
    for fruit in ("apple", "banana", "cherry"):
        assert_contains(text, fruit, f"{fruit} in TUI output")
    assert_bytes_contains(raw, b"\x1b[48;2;40;40;50m", "no pi-style tool block in TUI stream")

# ---------------------------------------------------------------------------
# Pytest driver. The script entrypoint below preserves the old smoke.py CLI by
# translating it into a pytest invocation.
# ---------------------------------------------------------------------------

def pytest_generate_tests(metafunc):
    if "smoke_case" not in metafunc.fixturenames:
        return
    selected = _selected_tests(
        metafunc.config.getoption("--filter"),
        metafunc.config.getoption("--exclude") or [],
    )
    metafunc.parametrize("smoke_case", selected, ids=[case[0] for case in selected])

@pytest.fixture
def psi(request, tmp_path: Path):
    binary = Path(request.config.getoption("--psi")).resolve()
    if not binary.exists():
        pytest.fail(f"psi binary not found at {binary}; build it or pass --psi", pytrace=False)
    env = _smoke_env(tmp_path)
    token = _CURRENT_TEST_ENV.set(env)
    try:
        yield Psi(str(binary), tmp_path, env)
    finally:
        _CURRENT_TEST_ENV.reset(token)

def _pytest_run_live(config) -> bool:
    return bool(os.environ.get("ANTHROPIC_API_KEY")) and not config.getoption("--no-live")

def test_smoke_case(smoke_case, psi: Psi, request):
    name, fn, meta = smoke_case
    if meta["live"] and not _pytest_run_live(request.config):
        pytest.skip("live smoke test requires ANTHROPIC_API_KEY")
    try:
        fn(psi)
    except Fail as err:
        pytest.fail(str(err), pytrace=False)

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--psi", default=str(ROOT / "build" / "psi"),
                    help="path to psi binary")
    ap.add_argument("--filter", default=None,
                    help="only run tests whose name contains this substring")
    ap.add_argument("--exclude", action="append", default=[],
                    help="skip tests whose name contains this substring; may be repeated")
    ap.add_argument("--no-live", action="store_true",
                    help="skip live-agent tests even if ANTHROPIC_API_KEY is set")
    ap.add_argument("--list", action="store_true",
                    help="list test names and exit")
    args, pytest_args = ap.parse_known_args()

    if args.list:
        for name, _fn, meta in _selected_tests(args.filter, args.exclude or []):
            tag = "(live)" if meta["live"] else ""
            print(f"{name} {tag}".rstrip())
        for case in lua_runner.discover(Path(__file__).resolve().parent):
            if args.filter and args.filter not in case.name:
                continue
            if any(ex in case.name for ex in (args.exclude or [])):
                continue
            print(case.name)
        return 0

    binary = str(Path(args.psi).resolve())
    if not Path(binary).exists():
        print(f"psi binary not found at {binary}; build it or pass --psi", file=sys.stderr)
        return 1

    # Invoke pytest on the whole tests/ directory so the declarative
    # tests/lua/ cases (collected via test_lua_cases.py) run alongside the
    # PTY/multi-step cases defined in this file.
    argv = [
        "--rootdir", str(ROOT),
        str(Path(__file__).resolve().parent),
        "--psi", binary,
        "-q",
    ]
    if args.filter:
        argv.extend(["--filter", args.filter])
    for excluded in args.exclude or []:
        argv.extend(["--exclude", excluded])
    if args.no_live:
        argv.append("--no-live")
    argv.extend(pytest_args)
    return pytest.main(argv)

if __name__ == "__main__":
    sys.exit(main())
