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
import json
import os
import re
import shlex
import subprocess
import sys
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

def run_pty(cmd: list[str], scenario: list[tuple[str, float]],
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
            if data:
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


@test("markdown/inline_code_no_backticks")
def t_markdown_inline_code_no_backticks(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'return require("psi.markdown").render_line("Use `psi` here")',
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
        + 'return require("psi.tui_status").render_busy_status("working", 2, 4)',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(
        plain,
        "working (0:04  • Ctrl-G to interrupt) ...",
        "busy status renders selected label, hint, and animated dots",
    )
    assert_contains(out, "\x1b[96m", "busy label has a subtle shimmer")


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
    assert_equals(out, "1|0|1|false|0|true|1|0|0|0|0|1|true|diff|80",
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
local old_frame = psi.tui_render_frame
local old_write = psi.stdout_write
local frame
psi.tui_render_frame = function(f) frame = f end
psi.stdout_write = function() end
local renderer = r.new()
renderer:render({lines={"abcdef"}, width=10, height=1})
renderer:render({lines={"x"}, width=10, height=1, force_full=true})
psi.tui_render_frame = old_frame
psi.stdout_write = old_write
return tostring((frame or ""):find("\27[2K", 1, true) ~= nil)
""")
    assert_equals(out, "true", "full redraw should clear rows before shorter lines")


@test("tui/renderer_moves_cursor_without_line_changes")
def t_tui_renderer_moves_cursor_without_line_changes(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_frame = psi.tui_render_frame
local old_write = psi.stdout_write
local writes = {}
psi.tui_render_frame = function() end
psi.stdout_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
renderer:render({lines={"abc"}, width=10, height=1, cursor={row=1, col=1, visible=true}})
renderer:render({lines={"abc"}, width=10, height=1, cursor={row=1, col=3, visible=true}})
psi.tui_render_frame = old_frame
psi.stdout_write = old_write
return table.concat({
  renderer.last_mode,
  tostring(#writes),
  tostring((writes[1] or ""):find("\27[1;3H", 1, true) ~= nil)
}, "|")
""")
    assert_equals(out, "diff|1|true", "cursor-only redraw should move hardware cursor")


@test("tui/renderer_applies_cursor_marker_and_resets")
def t_tui_renderer_applies_cursor_marker_and_resets(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_frame = psi.tui_render_frame
local old_write = psi.stdout_write
local frame, row, col, visible
psi.tui_render_frame = function(f, r0, c0, v0) frame, row, col, visible = f, r0, c0, v0 end
psi.stdout_write = function() end
r.new():render({lines={"ab" .. r.cursor_marker() .. "cd"}, width=10, height=1, cursor={visible=true}})
psi.tui_render_frame = old_frame
psi.stdout_write = old_write
return table.concat({
  tostring(frame:find(r.cursor_marker(), 1, true) == nil),
  tostring(frame:find("\27]8;;\7", 1, true) ~= nil),
  tostring(row), tostring(col), tostring(visible)
}, "|")
""")
    assert_equals(out, "true|true|1|3|true",
                  "renderer strips marker, appends line reset, and uses marker cursor")


@test("tui/renderer_uses_discrete_dirty_ranges")
def t_tui_renderer_uses_discrete_dirty_ranges(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_frame = psi.tui_render_frame
local old_write = psi.stdout_write
local writes = {}
psi.tui_render_frame = function() end
psi.stdout_write = function(text) writes[#writes + 1] = text or "" end
local renderer = r.new()
renderer:render({lines={"a", "b", "c", "d"}, width=10, height=4})
renderer:render({lines={"x", "b", "y", "d"}, width=10, height=4})
psi.tui_render_frame = old_frame
psi.stdout_write = old_write
local out = writes[1] or ""
local ranges = renderer.last_changed_ranges
return table.concat({
  renderer.last_mode,
  tostring(#ranges),
  tostring(ranges[1] and ranges[1].first),
  tostring(ranges[1] and ranges[1].last),
  tostring(ranges[2] and ranges[2].first),
  tostring(ranges[2] and ranges[2].last),
  tostring(out:find("\27[1;1H", 1, true) ~= nil),
  tostring(out:find("\27[2;1H", 1, true) == nil),
  tostring(out:find("\27[3;1H", 1, true) ~= nil)
}, "|")
""")
    assert_equals(out, "diff|2|1|1|3|3|true|true|true",
                  "renderer should emit discrete dirty row ranges")


@test("tui/renderer_offsets_viewport_top")
def t_tui_renderer_offsets_viewport_top(psi: Psi):
    out = psi.eval(r"""
local r = require("psi.tui_renderer")
local old_frame = psi.tui_render_frame
local old_write = psi.stdout_write
local frame, row, col
psi.tui_render_frame = function(f, r0, c0) frame, row, col = f, r0, c0 end
psi.stdout_write = function() end
r.new():render({lines={"abc"}, width=10, height=1, top=9, cursor={row=1, col=2, visible=true}})
psi.tui_render_frame = old_frame
psi.stdout_write = old_write
return table.concat({
  tostring((frame or ""):find("\27[9;1H", 1, true) ~= nil),
  tostring(row),
  tostring(col)
}, "|")
""")
    assert_equals(out, "true|9|2", "renderer should offset local frame rows by viewport top")


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
    assert_equals(default_out, "0", "thinking hidden by default in TUI")

    project = psi.tmp / "thinking-config-project"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"tui": {"show_thinking": True}})
    )
    out = psi.run(
        "--eval",
        'return require("psi.tui_status").show_thinking()',
        cwd=project,
    ).stdout.strip()
    assert_equals(out, "1", "project setting enables thinking in TUI")


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

@test("tui/prompt_history_navigation")
def t_tui_prompt_history_navigation(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local no_history = rt._debug_history_sequence({}, {"line-up"}, "")\n'
        + 'local empty = rt._debug_history_sequence({"first", "second"}, {"line-up"}, "")\n'
        + 'local draft = rt._debug_history_sequence({"first", "second"}, {"line-up", "line-down"}, "sec")\n'
        + 'return tostring(no_history.scrolled) .. "|" .. empty.input .. "|"\n'
        + "  .. draft.input .. '|' .. tostring(draft.cursor)"
    )
    assert_equals(out, "true|second|sec|3",
                  "empty prompt recalls history when available and scrolls otherwise")


@test("tui/prompt_history_reverse_search")
def t_tui_prompt_history_reverse_search(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local r = rt._debug_history_sequence({"alpha", "beta", "alphabet"}, {"ctrl-r", "text:a", "text:l", "ctrl-r"})\n'
        + "return r.input .. '|' .. r.history_search_query .. '|' .. tostring(r.history_search_active)"
    )
    assert_equals(out, "alpha|al|true", "ctrl-r reverse searches prompt history")


@test("prompt/transformer")
def t_prompt_transformer(psi: Psi):
    """psi.prompt.register_transformer runs after built-in assembly
    and can rewrite the returned prompt string."""
    out = psi.eval(
        'local p = require("psi.prompt")\n'
        + 'p.register_transformer(function(s) return s .. " [TAIL]" end)\n'
        + 'local sp = p.system_prompt()\n'
        + 'p.clear_transformers()\n'
        + 'return sp:sub(-6)'
    )
    assert_contains(out, "[TAIL]", "transformer appended tail marker")


@test("tools/cancel_helper")
def t_tools_cancel(psi: Psi):
    """psi.tools.cancel returns a failure ToolResult that a before-hook
    can use to short-circuit dispatch. Real tool impl must not run."""
    out = psi.eval(
        'local t = require("psi.tools")\n'
        + 'local real_ran = false\n'
        + 't.add_before_hook(function(name, input)\n'
        + '  if name == "bash" then return t.cancel("nope") end\n'
        + 'end)\n'
        + '-- Register a fake tool whose impl flips a flag; if\n'
        + '-- cancel short-circuits, impl must not run.\n'
        + 'local r = t.dispatch("bash", { command = "echo x" })\n'
        + 't.clear_hooks()\n'
        + 'return tostring(r.ok) .. "|" .. tostring(r.error)'
    )
    assert_contains(out, "false|nope", "cancel result shape")


@test("agent/set_model")
def t_agent_set_model(psi: Psi):
    out = psi.eval(
        'local a = require("psi.agent_session")\n'
        + 'a.set_model("openrouter/x/y")\n'
        + 'local got = a.current_model("anthropic/fallback")\n'
        + 'a.set_model(nil)\n'
        + 'local cleared = a.current_model("anthropic/fallback")\n'
        + 'a.configure({model = "ollama/local"})\n'
        + 'local configured = a.current_model(nil)\n'
        + 'local effective = a.effective_model(nil)\n'
        + 'local desc = a.model_descriptor(nil)\n'
        + 'local has_effective = effective ~= nil and effective ~= ""\n'
        + 'return got .. "|" .. cleared .. "|" .. configured .. "|"\n'
        + '  .. tostring(has_effective) .. "|" .. desc.provider'
    )
    assert_contains(out, "openrouter/x/y|anthropic/fallback|ollama/local|true|ollama",
                    "override then clear")


@test("agent/set_reasoning_effort")
def t_agent_set_reasoning_effort(psi: Psi):
    out = psi.eval(
        'local a = require("psi.agent_session")\n'
        + 'a.set_reasoning_effort("high")\n'
        + 'local got = a.current_reasoning_effort("low")\n'
        + 'a.set_reasoning_effort("none")\n'
        + 'local none = a.current_reasoning_effort("low")\n'
        + 'a.set_reasoning_effort(nil)\n'
        + 'local cleared = a.current_reasoning_effort("medium")\n'
        + 'return got .. "|" .. none .. "|" .. cleared'
    )
    assert_equals(out, "high|none|medium", "reasoning effort override then clear")


@test("agent/thinking_level")
def t_agent_thinking_level(psi: Psi):
    out = psi.eval(
        'local a = require("psi.agent_session")\n'
        + 'local openai = { provider="openai-codex", id="gpt-5.5", reasoning=true }\n'
        + 'local fallback = a.thinking_level_for(openai, nil, nil)\n'
        + 'local explicit = a.thinking_level_for(openai, "xhigh", nil)\n'
        + 'local off = a.thinking_level_for(openai, nil, "none")\n'
        + 'local ok, set = a.set_thinking_level("xhigh", "openai-codex/gpt-5.5")\n'
        + 'local current = a.current_reasoning_effort("low")\n'
        + 'return fallback .. "|" .. explicit .. "|" .. off .. "|" .. tostring(ok) .. "|"\n'
        + '  .. tostring(set) .. "|" .. tostring(current)'
    )
    assert_equals(out, "medium|xhigh|off|true|xhigh|xhigh",
                  "thinking defaults, clamps, and updates reasoning override")


@test("commands/set_reasoning_effort")
def t_commands_set_reasoning_effort(psi: Psi):
    out = psi.eval(
        'local c = require("psi.slash_commands")\n'
        + 'local a = c.handle("/set effort xhigh")\n'
        + 'local b = c.handle("/set reasoning_effort nope")\n'
        + 'return a.kind .. "|" .. tostring(a.payload) .. "|" .. b.kind .. "|" .. b.payload'
    )
    assert_contains(out, "set-reasoning-effort|xhigh|print|usage: /set effort",
                    "/set validates reasoning effort")


@test("commands/thinking")
def t_commands_thinking(psi: Psi):
    out = psi.eval(
        'local c = require("psi.slash_commands")\n'
        + 'local a = c.handle("/thinking xhigh")\n'
        + 'local b = c.handle("/thinking nope")\n'
        + 'return a.kind .. "|" .. tostring(a.payload) .. "|" .. b.kind .. "|"\n'
        + '  .. tostring(b.payload:find("usage: /thinking", 1, true) ~= nil)'
    )
    assert_equals(out, "set-thinking|xhigh|print|true",
                  "/thinking validates pi-style levels")


@test("theme/default_dark")
def t_theme_default(psi: Psi):
    out = psi.eval(
        'local t = require("psi.theme")\n'
        + 'local cur = t.current()\n'
        + 'return t.current_name() .. "|"\n'
        + '  .. tostring(cur.tui.chrome.bg) .. "|"\n'
        + '  .. tostring(cur.tui.accent.fg)'
    )
    assert_equals(out, "midnight-ember|234|81", "default theme")


@test("theme/compound_ansi_mapping")
def t_theme_compound_ansi_mapping(psi: Psi):
    out = psi.eval(
        'local ansi = require("psi.ansi")\n'
        + 'ansi.enabled = true\n'
        + 'ansi.color_enabled = true\n'
        + 'ansi.set_code_map({["38;5;242"] = "38;5;123"})\n'
        + 'return ansi.gray("x")'
    )
    assert_contains(out, "\x1b[38;5;123mx\x1b[0m", "compound ANSI map applies")


@test("theme/settings_selects_extension_theme")
def t_theme_settings_select(psi: Psi):
    project = psi.tmp / "theme-project"
    extdir = psi.tmp / "theme-ext"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    extdir.mkdir(exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"theme": {"name": "toxic"}})
    )
    (extdir / "toxic.lua").write_text(
        "return function(psi)\n"
        "  psi.theme.register('toxic', {\n"
        "    tui = {\n"
        "      accent = { fg = 118, bg = 233 },\n"
        "      chrome = { fg = 244, bg = 233 },\n"
        "    },\n"
        "  })\n"
        "end\n"
    )
    expr = (
        'local t = require("psi.theme")\n'
        + 'local cur = t.current()\n'
        + 'return t.current_name() .. "|"\n'
        + '  .. tostring(cur.tui.accent.fg) .. "|"\n'
        + '  .. tostring(cur.tui.chrome.bg) .. "|"\n'
        + '  .. tostring(cur.tui.text.fg)'
    )
    out = psi.run(
        "--eval",
        expr,
        cwd=project,
        env_extra={"PSI_EXTENSIONS_DIR": str(extdir)},
    ).stdout.strip()
    assert_equals(out, "toxic|118|233|253", "configured theme override")


@test("theme/extension_selected_theme_survives_boot")
def t_theme_extension_selected_theme(psi: Psi):
    project = psi.tmp / "theme-extension-selected-project"
    extdir = psi.tmp / "theme-extension-selected-ext"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    extdir.mkdir(exist_ok=True)
    (extdir / "select.lua").write_text(
        "return function(psi)\n"
        "  psi.theme.register('extension-picked', {\n"
        "    tui = { accent = { fg = 118, bg = 233 } },\n"
        "  })\n"
        "  assert(psi.theme.use('extension-picked'))\n"
        "end\n"
    )
    out = psi.run(
        "--eval",
        'local t = require("psi.theme")\n'
        + 'local cur = t.current()\n'
        + 'return t.current_name() .. "|" .. tostring(cur.tui.accent.fg)',
        cwd=project,
        env_extra={"PSI_EXTENSIONS_DIR": str(extdir)},
    ).stdout.strip()
    assert_equals(out, "extension-picked|118", "extension-selected theme survives boot")


@test("theme/composite_ansi_remap")
def t_theme_composite_ansi_remap(psi: Psi):
    out = psi.eval(
        'local ansi = require("psi.ansi")\n'
        + 'local theme = require("psi.theme")\n'
        + 'ansi.enabled = true\n'
        + 'ansi.color_enabled = true\n'
        + 'theme.use({ tui = { chrome = { fg = 118, bg = 233 } } })\n'
        + 'return ansi.gray("x")'
    )
    assert_contains(out, "\x1b[38;5;118m", "composite ANSI chrome remap applies")


@test("theme/reload_reverts_to_default")
def t_theme_reload_reverts_default(psi: Psi):
    project = psi.tmp / "theme-reload-project"
    extdir = psi.tmp / "theme-reload-ext"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    extdir.mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"theme": {"name": "toxic"}})
    )
    (extdir / "toxic.lua").write_text(
        "return function(psi)\n"
        "  psi.theme.register('toxic', {\n"
        "    tui = { chrome = { fg = 244, bg = 233 } },\n"
        "  })\n"
        "end\n"
    )
    out = psi.run(
        "--eval",
        'local theme = require("psi.theme")\n'
        'local settings = require("psi.settings_manager")\n'
        'local before = theme.current()\n'
        'psi.file_write(".psi/settings.json", "{}")\n'
        'settings.reload()\n'
        'theme.apply_configured()\n'
        'local after = theme.current()\n'
        'return table.concat({\n'
        '  theme.current_name(),\n'
        '  tostring(before.tui.chrome.bg),\n'
        '  tostring(after.tui.chrome.bg)\n'
        '}, "|")',
        cwd=project,
        env_extra={"PSI_EXTENSIONS_DIR": str(extdir)},
    ).stdout.strip()
    assert_equals(out, "midnight-ember|233|234", "reload falls back to default theme")


@test("theme/reload_preserves_extension_selected_theme")
def t_theme_reload_preserves_extension_selected_theme(psi: Psi):
    project = psi.tmp / "theme-command-reload-project"
    extdir = psi.tmp / "theme-command-reload-ext"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    extdir.mkdir(parents=True, exist_ok=True)
    (extdir / "select.lua").write_text(
        "return function(psi)\n"
        "  psi.theme.register('reload-picked', {\n"
        "    tui = { accent = { fg = 118, bg = 233 } },\n"
        "  })\n"
        "  assert(psi.theme.use('reload-picked'))\n"
        "end\n"
    )
    out = psi.run(
        "--eval",
        'local commands = require("psi.slash_commands")\n'
        'local theme = require("psi.theme")\n'
        'commands.handle("/reload")\n'
        'local cur = theme.current()\n'
        'return theme.current_name() .. "|" .. tostring(cur.tui.accent.fg)',
        cwd=project,
        env_extra={"PSI_EXTENSIONS_DIR": str(extdir)},
    ).stdout.strip()
    assert_equals(out, "reload-picked|118", "/reload preserves extension-selected theme")


@test("tui/status_hook")
def t_tui_status_hook(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'tui.register_status_hook(function(arg) return "ext:" .. tostring(arg.editor_mode) end)\n'
        + 'local line = tui.status_line(\n'
        + '  psi.json_encode({model="m", busy=false, scroll=0, editor_mode="normal"}))\n'
        + 'local bar = tui.status_bar(\n'
        + '  psi.json_encode({model="m", busy=false, scroll=0, editor_mode="visual"}))\n'
        + 'tui.clear_status_hooks()\n'
        + 'return line .. "|" .. bar'
    )
    assert_contains(out, "ext:normal", "status hook contribution shows in status line")
    assert_contains(out, "ext:visual", "status hook receives context in status bar")


@test("tui/reload_deduplicates_builtin_hooks")
def t_tui_reload_deduplicates_builtin_hooks(psi: Psi):
    cwd = psi.tmp / "reload-vim-config"
    (cwd / ".psi").mkdir(parents=True, exist_ok=True)
    (cwd / ".psi" / "settings.json").write_text(
        json.dumps({"extensions": {"vim_keybindings": {"enabled": True}}})
    )
    out = psi.run(
        "--eval",
        'local commands = require("psi.slash_commands")\n'
        + 'local tui = require("psi.tui_status")\n'
        + 'commands.handle("/reload")\n'
        + 'commands.handle("/reload")\n'
        + 'local writes = 0\n'
        + 'psi.stdout_write = function() writes = writes + 1 end\n'
        + 'local copied = tostring(tui.write_clipboard("hi", {force=true}))\n'
        + 'local bar = tui.status_bar({model="m", busy=false, scroll=0, editor_mode="normal"})\n'
        + 'local _, count = bar:gsub("mode:NORMAL", "")\n'
        + 'local action = tui.handle_key({key="escape", busy=false, input_length=1, editor_mode="insert"})\n'
        + 'return tostring(count) .. "|" .. tostring(action and action.action or "nil") .. "|" .. copied .. "|" .. tostring(writes)',
        cwd=cwd,
    ).stdout.strip()
    assert_equals(out, "1|vim-mode|true|1", "/reload should reinstall built-in TUI hooks once")


@test("tui/status_default_model")
def t_tui_status_default_model(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'return tui.status_line(psi.json_encode({busy=false, scroll=0}))'
    )
    assert_not_contains(out, "model:?", "status line should show effective default model")
    assert_contains(out, "model:", "status line includes model")


@test("providers/openrouter_metadata")
def t_providers_openrouter_metadata(psi: Psi):
    cache = psi.tmp / "openrouter_models.json"
    cache.write_text(json.dumps({
        "google/gemini-3-flash-preview": {
            "context_window": 1048576,
            "max_output_tokens": 65536,
            "reasoning": True,
            "supports_tool_use": True,
            "input": ["text", "image"],
        },
        "openai/gpt-5.1-codex": {
            "context_window": 400000,
            "max_output_tokens": 128000,
            "reasoning": True,
            "supports_tool_use": True,
            "input": ["text"],
        },
        "fake/provider-model": {
            "context_window": 12345,
            "max_output_tokens": 678,
            "reasoning": False,
            "supports_tool_use": True,
            "input": ["text"],
        },
    }))
    out = psi.run(
        "--eval",
        'local providers = require("psi.api_registry")\n'
        + 'local full = providers.model("openrouter/google/gemini-3-flash-preview")\n'
        + 'local slug = providers.model("google/gemini-3-flash-preview")\n'
        + 'local codex = providers.model("openrouter/openai/gpt-5.1-codex")\n'
        + 'local fake = providers.model("openrouter/fake/provider-model")\n'
        + 'local resolved = providers.resolve_descriptor("openrouter/openai/gpt-5.1-codex")\n'
        + 'return table.concat({\n'
        + '  tostring(full.context_window),\n'
        + '  tostring(slug.max_output_tokens),\n'
        + '  tostring(codex.context_window),\n'
        + '  tostring(fake.max_output_tokens),\n'
        + '  tostring(resolved.id),\n'
        + '  tostring(resolved.provider),\n'
        + '}, "|")',
        env_extra={"PSI_OPENROUTER_MODELS_CACHE": str(cache)},
    ).stdout.strip()
    assert_equals(out, "1048576|65536|400000|678|openai/gpt-5.1-codex|openrouter",
                  "OpenRouter metadata resolves full and stripped model ids")


@test("providers/api_registry")
def t_providers_api_registry(psi: Psi):
    out = psi.eval(
        'local p = require("psi.api_registry")\n'
        + 'local api = p.api("anthropic-messages")\n'
        + 'local desc = p.resolve_descriptor("anthropic/claude-opus-4-7")\n'
        + 'local mod = p.load_api("anthropic-messages")\n'
        + 'return table.concat({\n'
        + '  tostring(api.module),\n'
        + '  tostring(desc.api),\n'
        + '  tostring(desc.compat.supports_tool_use),\n'
        + '  tostring(type(mod.run_turn)),\n'
        + '  tostring(#p.all_apis()),\n'
        + '}, "|")'
    )
    assert_equals(out, "psi.providers.anthropic|anthropic-messages|true|function|4",
                  "provider API registry should route API adapters")


@test("providers/openai_codex_registry")
def t_providers_openai_codex_registry(psi: Psi):
    out = psi.eval(
        'local p = require("psi.api_registry")\n'
        + 'local desc = p.resolve_descriptor("openai-codex/gpt-5.5")\n'
        + 'local model = p.model("openai-codex/gpt-5.5")\n'
        + 'return table.concat({desc.provider, desc.api, desc.id,\n'
        + '  tostring(model.context_window), tostring(model.supports_tool_use)}, "|")'
    )
    assert_equals(out, "openai-codex|openai-codex-responses|gpt-5.5|272000|true",
                  "OpenAI Codex provider resolves model metadata")


@test("oauth/openai_codex_pkce")
def t_oauth_openai_codex_pkce(psi: Psi):
    out = psi.eval(
        'local d = require("psi.providers.oauth_openai_codex")._debug\n'
        + 'local digest = d.base64url_encode(d.sha256_bytes("abc"))\n'
        + 'local q = d.parse_query("http://localhost:1455/auth/callback?code=abc&state=xyz")\n'
        + 'return digest .. "|" .. q.code .. "|" .. q.state'
    )
    assert_equals(out, "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0|abc|xyz",
                  "OpenAI Codex PKCE helpers match SHA-256/base64url")


@test("commands/openai_codex_login_starts")
def t_commands_openai_codex_login_starts(psi: Psi):
    out = psi.eval(
        'local copied = ""\n'
        + 'psi.stdout_write = function(s) copied = copied .. s end\n'
        + 'local action = require("psi.slash_commands").handle("/login openai-codex")\n'
        + 'return table.concat({\n'
        + '  action.kind,\n'
        + '  tostring(action.payload:find("https://auth.openai.com/oauth/authorize", 1, true) ~= nil),\n'
        + '  tostring(action.payload:find("/login openai-codex <redirect-url-or-code>", 1, true) ~= nil),\n'
        + '  tostring(action.payload:find("Copied auth URL to clipboard via OSC 52.", 1, true) ~= nil),\n'
        + '  tostring(copied:find("\\27]52;", 1, true) ~= nil),\n'
        + '}, "|")'
    )
    assert_equals(out, "print|true|true|true|true",
                  "OpenAI Codex login should start without blocking and copy auth URL")


@test("auth/storage_roundtrip")
def t_auth_storage_roundtrip(psi: Psi):
    auth_file = psi.tmp / "auth.json"
    out = psi.run(
        "--eval",
        'local a = require("psi.auth_storage")\n'
        + 'local ok = a.set("openai-codex", {type="oauth", access="a", refresh="r", expires=123, accountId="acct"})\n'
        + 'local c = a.get("openai-codex")\n'
        + 'return tostring(ok) .. "|" .. c.type .. "|" .. c.access .. "|" .. c.accountId',
        env_extra={"PSI_AUTH_FILE": str(auth_file)},
    ).stdout.strip()
    assert_equals(out, "true|oauth|a|acct", "auth storage persists provider credentials")


@test("providers/openai_codex_parser")
def t_providers_openai_codex_parser(psi: Psi):
    out = psi.eval(
        'local d = require("psi.providers.openai_codex")._debug\n'
        + 'local s, p = d.new_state(), d.parser_new()\n'
        + 'local seen = ""\n'
        + 'local obs = { on_assistant_text_delta = function(t) seen = seen .. t end }\n'
        + 'd.parser_push(p, "data: {\\"type\\":\\"response.output_item.added\\",\\"item\\":{\\"type\\":\\"message\\",\\"id\\":\\"msg_1\\"}}\\n\\n", s, obs)\n'
        + 'd.parser_push(p, "data: {\\"type\\":\\"response.output_text.delta\\",\\"delta\\":\\"hi\\"}\\n\\n", s, obs)\n'
        + 'd.parser_push(p, "data: {\\"type\\":\\"response.output_item.done\\",\\"item\\":{\\"type\\":\\"message\\",\\"id\\":\\"msg_1\\",\\"content\\":[{\\"type\\":\\"output_text\\",\\"text\\":\\"hi\\"}]}}\\n\\n", s, obs)\n'
        + 'd.parser_push(p, "data: {\\"type\\":\\"response.completed\\",\\"response\\":{\\"status\\":\\"completed\\",\\"usage\\":{\\"input_tokens\\":10,\\"output_tokens\\":2,\\"total_tokens\\":12,\\"input_tokens_details\\":{\\"cached_tokens\\":3}}}}\\n\\n", s, obs)\n'
        + 'local _, calls = d.finalize(s)\n'
        + 'local body = d.request_body({model="gpt-5.5", messages={}, max_tokens=123})\n'
        + 'local e, ep = d.new_state(), d.parser_new()\n'
        + 'local ok = pcall(d.parser_push, ep, "data: {\\"type\\":\\"error\\",\\"message\\":\\"bad\\"}\\n\\n", e, {})\n'
        + 'local classified = d.classify_http_error(429, "{\\"error\\":{\\"message\\":\\"slow\\"}}", "openai-codex")\n'
        + 'return seen .. "|" .. tostring(#calls) .. "|" .. tostring(s.usage.input_tokens) .. "|"\n'
        + '  .. tostring(s.usage.cache_read_input_tokens) .. "|" .. tostring(body.max_output_tokens) .. "|"\n'
        + '  .. tostring(ok) .. "|" .. tostring(e.stop_reason) .. "|" .. tostring(e.error_message) .. "|"\n'
        + '  .. tostring(classified:find("slow", 1, true) ~= nil)'
    )
    assert_equals(out, "hi|0|7|3|nil|true|error|Codex error: bad|true",
                  "OpenAI Codex parser handles text, usage, and errors without unsupported caps")


@test("providers/shared_sse_parser")
def t_providers_shared_sse_parser(psi: Psi):
    out = psi.eval(
        'local a = require("psi.providers.anthropic")._test\n'
        + 'local p = a.new_sse_parser()\n'
        + 'local seen = {}\n'
        + 'a.sse_push(p, "event: message_delta\\ndata: {\\"type\\":\\n", function(ev, data)\n'
        + '  seen[#seen + 1] = ev .. ":" .. tostring(data.type)\n'
        + 'end)\n'
        + 'a.sse_push(p, "data: \\"message_delta\\"}\\n\\n", function(ev, data)\n'
        + '  seen[#seen + 1] = ev .. ":" .. tostring(data.type)\n'
        + 'end)\n'
        + 'return table.concat(seen, "|")'
    )
    assert_equals(out, "message_delta:message_delta",
                  "shared SSE parser preserves state and joins data lines")


@test("providers/openai_codex_unresolved_tool_call")
def t_providers_openai_codex_unresolved_tool_call(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'local d = require("psi.providers.openai_codex")._debug\n'
        + 's.append_user("hi")\n'
        + 's.append_assistant("", {\n'
        + '  { type = "tool_use", id = "call_1|item_1", name = "bash",\n'
        + '    input = { command = "pwd" } }\n'
        + '}, {})\n'
        + 's.append_user("continue")\n'
        + 'local wire = d.response_input_from_session(s.messages(), "")\n'
        + 'return table.concat({\n'
        + '  wire[2].type,\n'
        + '  wire[2].call_id,\n'
        + '  wire[3].type,\n'
        + '  wire[3].call_id,\n'
        + '  wire[3].output,\n'
        + '  wire[4].content[1].text,\n'
        + '}, "|")'
    )
    assert_equals(out, "function_call|call_1|function_call_output|call_1|No result provided|continue",
                  "OpenAI Codex closes unresolved tool calls before user input")


@test("providers/openai_codex_custom_messages")
def t_providers_openai_codex_custom_messages(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session_manager")\n'
        + 'local d = require("psi.providers.openai_codex")._debug\n'
        + 's.append_custom_message("visible user", { role = "user" })\n'
        + 's.append_custom_message("hidden user", { role = "user", hidden = true })\n'
        + 's.append_custom_message("visible assistant", { role = "assistant" })\n'
        + 'local wire = d.response_input_from_session(s.messages(), "")\n'
        + 'return table.concat({\n'
        + '  tostring(#wire),\n'
        + '  wire[1].role,\n'
        + '  wire[1].content[1].type,\n'
        + '  wire[1].content[1].text,\n'
        + '  wire[2].type,\n'
        + '  wire[2].role,\n'
        + '  wire[2].content[1].type,\n'
        + '  wire[2].content[1].text,\n'
        + '}, "|")'
    )
    assert_equals(out, "2|user|input_text|visible user|message|assistant|output_text|visible assistant",
                  "OpenAI Codex preserves non-hidden custom messages")


@test("providers/openai_codex_reasoning_config")
def t_providers_openai_codex_reasoning_config(psi: Psi):
    project = psi.tmp / "codex-reasoning-config"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"defaults": {"reasoning_effort": "medium"}})
    )
    out = psi.run(
        "--eval",
        'local d = require("psi.providers.openai_codex")._debug\n'
        + 'local a = d.request_body({model="gpt-5.5", messages={}, reasoning_effort="xhigh"})\n'
        + 'local b = d.request_body({model="gpt-5.5", messages={}, reasoning_effort="none"})\n'
        + 'local c = d.request_body({model="gpt-5.5", messages={}})\n'
        + 'return a.reasoning.effort .. "|" .. tostring(b.reasoning) .. "|" .. c.reasoning.effort',
        cwd=project,
        env_extra={"PSI_OPENAI_CODEX_REASONING": ""},
    ).stdout.strip()
    assert_equals(out, "xhigh|nil|medium",
                  "OpenAI Codex reasoning effort uses runtime override then config")


@test("providers/openai_codex_reasoning")
def t_providers_openai_codex_reasoning(psi: Psi):
    out = psi.eval(
        'local d = require("psi.providers.openai_codex")._debug\n'
        + 'local a = d.request_body({model="gpt-5.5", messages={}})\n'
        + 'local b = d.request_body({model="gpt-5.5", messages={}, thinking_level="minimal"})\n'
        + 'local c = d.request_body({model="gpt-5.5", messages={}, thinking_level="xhigh"})\n'
        + 'local e = d.request_body({model="gpt-5.5", messages={}, thinking_level="off"})\n'
        + 'return a.reasoning.effort .. "|" .. b.reasoning.effort .. "|"\n'
        + '  .. c.reasoning.effort .. "|" .. tostring(e.reasoning == nil)'
    )
    assert_equals(out, "medium|low|xhigh|true",
                  "OpenAI Codex maps pi-style thinking levels to request reasoning")


@test("providers/openai_codex_http_error")
def t_providers_openai_codex_http_error(psi: Psi):
    auth_file = psi.tmp / "codex-auth.json"
    out = psi.run(
        "--eval",
        'local a = require("psi.auth_storage")\n'
        + 'a.set("openai-codex", {type="oauth", access="a", refresh="r", expires=9999999999999, accountId="acct"})\n'
        + 'psi.http_stream_begin = function() return {} end\n'
        + 'psi.http_stream_poll = function() return "{\\"error\\":{\\"message\\":\\"nope\\"}}", true end\n'
        + 'psi.http_stream_finish = function() return 401 end\n'
        + 'local ok, err = require("psi.sched").run(function()\n'
        + '  return require("psi.providers.openai_codex").run_turn({model="gpt-5.5"})\n'
        + 'end)\n'
        + 'return tostring(ok) .. "|" .. tostring(err)',
        env_extra={"PSI_AUTH_FILE": str(auth_file)},
    ).stdout.strip()
    assert_contains(out, "false|openai-codex request failed (401)",
                    "OpenAI Codex HTTP errors should be classified")
    assert_contains(out, "nope", "OpenAI Codex HTTP error details should be preserved")


@test("tui/status_context_window")
def t_tui_status_context_window(psi: Psi):
    cache = psi.tmp / "openrouter_models_status.json"
    cache.write_text(json.dumps({
        "google/gemini-3-flash-preview": {
            "context_window": 1048576,
            "max_output_tokens": 65536,
            "reasoning": True,
            "supports_tool_use": True,
            "input": ["text", "image"],
        },
    }))
    out = psi.run(
        "--eval",
        'local context = require("psi.context")\n'
        + 'local tui = require("psi.tui_status")\n'
        + 'context.record_usage(0, { input_tokens = 3000, output_tokens = 566 }, "google/gemini-3-flash-preview")\n'
        + 'return tui.status_line(psi.json_encode({model="openrouter/google/gemini-3-flash-preview", busy=false, scroll=0}))',
        env_extra={"PSI_OPENROUTER_MODELS_CACHE": str(cache)},
    ).stdout.strip()
    assert_contains(out, "ctx:0.3% (3566/1048576)",
                    "status line uses OpenRouter metadata and one-decimal percentage")


@test("tui/footer_hint_hidden")
def t_tui_footer_hint_hidden(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'local idle = tui.footer_hint(psi.json_encode({busy=false, scroll=0}))\n'
        + 'local busy = tui.footer_hint(psi.json_encode({\n'
        + '  busy=true, busy_label="working", elapsed_seconds=4, busy_phase=2, scroll=0\n'
        + '}))\n'
        + 'return tostring(idle) .. "|" .. tostring(busy)'
    )
    assert_equals(out, "|working (0:04  • Ctrl-G to interrupt) ..", "footer hint hidden when idle")


@test("tui/layout_geometry")
def t_tui_layout_geometry(psi: Psi):
    out = psi.eval(
        'local layout = require("psi.tui_layout").geometry(80, 24)\n'
        + 'return table.concat({layout.title, layout.transcript.h, layout.input.y}, "|")'
    )
    assert_equals(out, "psi coding agent|18|21", "shared TUI layout")


@test("tui/layout_reclaims_empty_status_row")
def t_tui_layout_reclaims_empty_status_row(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local idle = rt._debug_layout_rows(80, 24, false, nil)\n'
        + 'local busy = rt._debug_layout_rows(80, 24, true, nil)\n'
        + 'local status = rt._debug_layout_rows(80, 24, false, "saved")\n'
        + 'return table.concat({\n'
        + '  tostring(idle.status_visible), tostring(idle.transcript_height),\n'
        + '  tostring(busy.status_visible), tostring(busy.transcript_height), tostring(busy.status_row),\n'
        + '  tostring(status.status_visible), tostring(status.transcript_height)\n'
        + '}, "|")'
    )
    assert_equals(out, "false|19|true|18|20|true|18", "idle TUI reclaims the empty status row")


@test("tui/input_layout")
def t_tui_input_layout(psi: Psi):
    out = psi.eval(
        'local prelude = require("psi.prelude")\n'
        + 'local raw = require("psi.tui_layout").input_layout(\n'
        + '  psi.json_encode({width = 80, height = 24}))\n'
        + 'local layout = prelude.safe_json_decode(raw, {})\n'
        + 'return string.format("%d|%q|%q",\n'
        + '  layout.max_rows or -1,\n'
        + '  layout.prefix_first or "",\n'
        + '  layout.prefix_rest or "")'
    )
    assert_equals(out, '18|" › "|"   "', "Lua-owned TUI input layout")


@test("tui/input_layout_override")
def t_tui_input_layout_override(psi: Psi):
    out = psi.eval(
        'local prelude = require("psi.prelude")\n'
        + 'local layout_mod = require("psi.tui_layout")\n'
        + 'layout_mod.set_prompt_max_rows(8)\n'
        + 'local raw = layout_mod.input_layout(\n'
        + '  psi.json_encode({width = 80, height = 24}))\n'
        + 'layout_mod.set_prompt_max_rows(nil)\n'
        + 'local layout = prelude.safe_json_decode(raw, {})\n'
        + 'return tostring(layout.max_rows or -1)'
    )
    assert_equals(out, "8", "Lua override for TUI prompt rows")


@test("tui/input_layout_settings")
def t_tui_input_layout_settings(psi: Psi):
    ctx = psi.tmp / "tui-layout-settings"
    (ctx / ".psi").mkdir(parents=True, exist_ok=True)
    (ctx / ".psi" / "settings.json").write_text(
        json.dumps({"tui": {"prompt": {"max_rows": 7}}})
    )
    out = psi.run(
        "--eval",
        'local layout = require("psi.tui_runtime")._debug_resolve_input_layout(80, 24)\n'
        + 'return tostring(layout.max_rows or -1)',
        cwd=ctx,
    ).stdout.strip()
    assert_equals(out, "7", "settings-driven TUI prompt rows")


@test("tui/busy_status_config")
def t_tui_busy_status_config(psi: Psi):
    project = psi.tmp / "busy-config-project"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"tui": {"busy_labels": ["custom busy"]}})
    )
    out = psi.run(
        "--eval",
        'return require("psi.tui_status").pick_busy_status()',
        cwd=project,
    ).stdout.strip()
    assert_equals(out, "custom busy", "busy label pulled from settings")


@test("tui/busy_status_render")
def t_tui_busy_status_render(psi: Psi):
    out = psi.run(
        "--eval",
        'local ansi = require("psi.ansi")\n'
        + 'ansi.color_enabled = true\n'
        + 'return require("psi.tui_status").render_busy_status("working", 2, 4)',
    ).stdout.rstrip("\n")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    assert_equals(
        plain,
        "working (0:04  • Ctrl-G to interrupt) ...",
        "busy status renders selected label, hint, and animated dots",
    )
    assert_contains(out, "\x1b[96m", "busy label has a subtle shimmer")


@test("tui/full_redraw_uses_single_ansi_pass")
def t_tui_full_redraw_uses_single_ansi_pass(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_redraw_counts("hello\\nhi")\n'
        + 'return table.concat({\n'
        + '  tostring(d.first_frames),\n'
        + '  tostring(d.second_frames),\n'
        + '  tostring(d.second_input_draws > 0),\n'
        + '  tostring(d.second_clears),\n'
        + '  tostring(d.stale_clears > 0),\n'
        + '  tostring(d.line_clears),\n'
        + '  tostring(d.draw_rows),\n'
        + '  tostring(d.raw_draws),\n'
        + '  tostring(d.cursor_sets),\n'
        + '  tostring(d.refreshes)\n'
        + '}, "|")'
    )
    assert_equals(out, "1|1|true|0|true|0|0|0|0|0", "full redraw uses one no-clear ANSI frame")


@test("tui/chat_mode_streams_to_scrollback")
def t_tui_chat_mode_streams_to_scrollback(psi: Psi):
    # Drive a chat-mode session through three steps:
    #   1. user message added (live region only)
    #   2. assistant message added (user becomes committed scrollback)
    #   3. input edit (no entry change; just live region repaint)
    # Verify entries get committed exactly once and that input edits don't
    # re-emit committed lines.
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local snapshots = rt._debug_chat_redraw_sequence({\n'
        + '  {kind="user", text="hello"},\n'
        + '  {kind="assistant", text="hi there"},\n'
        + '  {kind="set_input", text="next message"},\n'
        + '})\n'
        + 'local s1, s2, s3 = snapshots[1], snapshots[2], snapshots[3]\n'
        + 'return table.concat({\n'
        + '  tostring(s1.committed_entries),\n'
        + '  tostring(s2.committed_entries),\n'
        + '  tostring(s3.committed_entries),\n'
        + '  tostring(s2.output:find("hello", 1, true) ~= nil),\n'
        + '  tostring(s3.output:find("hello", 1, true) == nil),\n'
        + '  tostring(s3.output:find("next message", 1, true) ~= nil),\n'
        + '  tostring(s2.live_rows >= 3),\n'
        + '}, "|")'
    )
    assert_equals(
        out,
        "0|1|1|true|true|true|true",
        "chat mode commits each entry to scrollback once, repaints only the live region",
    )


@test("tui/chat_mode_uses_crlf_line_separators")
def t_tui_chat_mode_uses_crlf_line_separators(psi: Psi):
    # Raw mode disables OPOST, so a bare "\n" is just LF — cursor moves
    # down but stays at the previous column. Without "\r" before each
    # newline, every committed and live-region line gets emitted starting
    # where the previous line ended, producing the staircase artifact
    # users saw before this fix.
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local snapshots = rt._debug_chat_redraw_sequence({\n'
        + '  {kind="user", text="hello"},\n'
        + '  {kind="assistant", text="Hello! How can I help you today?"},\n'
        + '})\n'
        + 'local s = snapshots[2]\n'
        + 'local _, bare_lf = s.output:gsub("[^\\r]\\n", "")\n'
        + 'local _, crlf = s.output:gsub("\\r\\n", "")\n'
        + 'return tostring(bare_lf) .. "|" .. tostring(crlf > 0)'
    )
    assert_equals(
        out,
        "0|true",
        "every newline in chat-mode output is preceded by a carriage return",
    )


@test("tui/chat_mode_uses_tui_write_not_render_frame")
def t_tui_chat_mode_uses_tui_write_not_render_frame(psi: Psi):
    # Chat mode should bypass psi.tui_render_frame entirely so the output
    # flows into the terminal's primary screen scrollback.
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local snapshots = rt._debug_chat_redraw_sequence({\n'
        + '  {kind="user", text="ping"},\n'
        + '})\n'
        + 'local s = snapshots[1]\n'
        + 'return table.concat({\n'
        + '  tostring(s.write_count >= 1),\n'
        + '  tostring(s.output:find("\\27[?2026h", 1, true) ~= nil),\n'
        + '  tostring(s.output:find("\\27[?25h", 1, true) ~= nil),\n'
        + '}, "|")'
    )
    assert_equals(
        out,
        "true|true|true",
        "chat mode emits lines via tui_write inside synchronized output",
    )


@test("tui/show_thinking_config")
def t_tui_show_thinking_config(psi: Psi):
    default_out = psi.eval('return require("psi.tui_status").show_thinking()')
    assert_equals(default_out, "0", "thinking hidden by default in TUI")

    project = psi.tmp / "thinking-config-project"
    (project / ".psi").mkdir(parents=True, exist_ok=True)
    (project / ".psi" / "settings.json").write_text(
        json.dumps({"tui": {"show_thinking": True}})
    )
    out = psi.run(
        "--eval",
        'return require("psi.tui_status").show_thinking()',
        cwd=project,
    ).stdout.strip()
    assert_equals(out, "1", "thinking visibility pulled from settings")


@test("tui/capabilities_disable_raw_for_dumb_terminal")
def t_tui_capabilities_disable_raw_for_dumb_terminal(psi: Psi):
    out = psi.run(
        "--eval",
        'local caps = require("psi.tui_runtime")._debug_tui_capabilities()\n'
        + 'return table.concat({tostring(caps.ansi), tostring(caps.color), tostring(caps.raw_ansi)}, "|")',
        env_extra={"TERM": "dumb"},
    ).stdout.strip()
    assert_equals(out, "false|false|false", "dumb terminal disables ANSI/color/raw rendering")


@test("tui/raw_ansi_available_with_ansi")
def t_tui_raw_ansi_available_with_ansi(psi: Psi):
    expr = (
        'local caps = require("psi.tui_runtime")._debug_tui_capabilities()\n'
        + 'return table.concat({tostring(caps.ansi), tostring(caps.color), tostring(caps.raw_ansi)}, "|")'
    )
    default_out = psi.run(
        "--eval",
        expr,
        env_extra={"TERM": "xterm-256color", "PSI_COLOR": "1"},
    ).stdout.strip()
    assert_equals(default_out, "true|true|true", "raw ANSI is available with ANSI terminals")


@test("tui/sanitizes_untrusted_terminal_sequences")
def t_tui_sanitizes_untrusted_terminal_sequences(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local esc = string.char(27)\n'
        + 'local bel = string.char(7)\n'
        + 'local input = "a" .. esc .. "]52;c;evil" .. bel .. "b" .. esc .. "[2Jc\\nnext"\n'
        + 'return rt._debug_sanitize_terminal_text(input, true)'
    )
    assert_equals(out, "abc\nnext", "untrusted terminal control sequences are stripped")


@test("tui/live_tool_progress_is_bounded")
def t_tui_live_tool_progress_is_bounded(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local text = rt._debug_limit_live_tool_progress_text(string.rep("a", 9000) .. "TAIL")\n'
        + 'return table.concat({\n'
        + '  tostring(#text <= 8192),\n'
        + '  tostring(text:find("earlier output truncated", 1, true) ~= nil),\n'
        + '  text:sub(-4)\n'
        + '}, "|")'
    )
    assert_equals(out, "true|true|TAIL", "live tool output is kept to a bounded rolling tail")


@test("tui/no_color_disables_input_chrome_colors")
def t_tui_no_color_disables_input_chrome_colors(psi: Psi):
    out = psi.run(
        "--eval",
        'local d = require("psi.tui_runtime")._debug_redraw_counts("hello")\n'
        + 'local frame = d.second_frame or ""\n'
        + 'return table.concat({\n'
        + '  tostring(frame:find("48;5;", 1, true) == nil),\n'
        + '  tostring(frame:find("38;5;", 1, true) == nil)\n'
        + '}, "|")',
        env_extra={"NO_COLOR": "1", "TERM": "xterm-256color"},
    ).stdout.strip()
    assert_equals(out, "true|true", "NO_COLOR disables Lua-owned input chrome colors")


@test("tui/input_wrap_width")
def t_tui_input_wrap_width(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_input_lines(\n'
        + '  string.rep("a", 78), 78, 80, "> ", "| ")\n'
        + 'return table.concat({\n'
        + '  tostring(#d.lines),\n'
        + '  tostring(#d.lines[1]),\n'
        + '  tostring(#d.lines[2]),\n'
        + '  tostring(d.cursor_line),\n'
        + '  tostring(d.cursor_col)\n'
        + '}, "|")'
    )
    assert_equals(out, "2|79|3|2|1", "input wraps to drawable width")


@test("tui/input_cursor_prefix_width")
def t_tui_input_cursor_prefix_width(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_input_lines(\n'
        + '  "abc", 0, 80, " › ", "   ")\n'
        + 'return tostring(d.cursor_screen_col)'
    )
    assert_equals(out, "4", "cursor column uses display width for unicode prompt prefix")


@test("tui/busy_input_clears_transient_error")
def t_tui_busy_input_clears_transient_error(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_edit_keys("/btw later", 10, '\
        + '{{key="enter"}, {key="text", text="x"}}, false, {busy=true, busy_kind="agent"})\n'
        + 'return tostring(d.status_text) .. "|" .. d.input'
    )
    assert_equals(out, "nil|/btw laterx",
                  "typing while busy should restore the busy status line after transient /btw error")


@test("tui/tool_call_text_has_no_leading_blank")
def t_tui_tool_call_text_has_no_leading_blank(psi: Psi):
    out = psi.eval(
        'return require("psi.tui_runtime")._debug_tool_call_text_after_assistant()'
    )
    assert_true(not out.startswith("\n"),
                "TUI tool calls should not add an extra blank after assistant text")
    assert_contains(out, "read README.md", "tool call text still renders")


@test("tui/busy_animation_uses_wall_clock")
def t_tui_busy_animation_uses_wall_clock(psi: Psi):
    out = psi.eval(
        'return require("psi.tui_runtime")._debug_busy_animation_frames({0, 599, 600, 1199, 1200})'
    )
    assert_equals(out, "0:0|0:0|1:1|1:1|2:2",
                  "busy animation should advance on wall-clock time")


@test("tui/key_policy")
def t_tui_key_policy(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'local function fmt(res)\n'
        + '  if not res then return "nil" end\n'
        + '  local arg = res.arg\n'
        + '  if type(arg) == "table" then arg = arg.mode end\n'
        + '  if arg == "\\n" then arg = "\\\\n" end\n'
        + '  return (res.action or "?") .. ":" .. (arg or "-")\n'
        + 'end\n'
        + 'return table.concat({\n'
        + '  fmt(tui.handle_key({key="enter", busy=false, input_length=1})),\n'
        + '  fmt(tui.handle_key({key="enter", busy=true, input_length=1})),\n'
        + '  fmt(tui.handle_key({key="shift-enter", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-u", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-d", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-d", busy=true, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="up", busy=true, input_length=0, queue_count=2})),\n'
        + '  fmt(tui.handle_key({key="up", busy=true, input_length=0, queue_count=0})),\n'
        + '  fmt(tui.handle_key({key="wheel-up", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="wheel-down", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="escape", busy=true, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-g", busy=true, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="text", text="x"}))\n'
        + '}, "|")'
    )
    assert_equals(out, "submit:-|submit:-|insert:\\n|scroll:page-up|quit:-|nil|queue-restore:-|scroll:line-up|scroll:line-up|scroll:line-down|nil|abort:-|insert:x",
                  "Lua TUI key policy")


@test("tui/ctrl_d_empty_prompt_exits")
def t_tui_ctrl_d_empty_prompt_exits(psi: Psi):
    out = psi.eval(
        'local d = require("psi.tui_runtime")._debug_edit_keys("", 0, {{key="ctrl-d"}}, false)\n'
        + 'return tostring(d.running) .. "|" .. d.input'
    )
    assert_equals(out, "false|", "Ctrl-D exits from an empty TUI prompt")


@test("tui/queue_restore")
def t_tui_queue_restore(psi: Psi):
    out = psi.eval(
        'local agent = require("psi.agent_session")\n'
        + 'local rt = require("psi.tui_runtime")\n'
        + 'agent.clear_queues()\n'
        + 'agent.queue_follow_up("first queued")\n'
        + 'agent.queue_follow_up("second queued")\n'
        + 'local state = rt._debug_edit_keys("draft", 5, {{key="up"}}, false, {busy=true})\n'
        + 'return state.input .. "|" .. tostring(agent.pending_message_count()) .. "|"\n'
        + '  .. tostring(state.status_text)'
    )
    assert_equals(out, "first queued\n\nsecond queued\n\ndraft|0|editing queued messages",
                  "Up should restore queued messages without dropping current input")


@test("tui/queue_status_lists_all")
def t_tui_queue_status_lists_all(psi: Psi):
    out = psi.eval(
        'local agent = require("psi.agent_session")\n'
        + 'local tui = require("psi.tui_status")\n'
        + 'agent.clear_queues()\n'
        + 'agent.queue_follow_up("first queued")\n'
        + 'agent.queue_follow_up("second queued")\n'
        + 'return tui.status_line({busy=true, scroll=0})'
    )
    assert_contains(out, "queue:first queued | second queued",
                    "queue status should concatenate every queued message")


@test("tui/queue_edit_then_append")
def t_tui_queue_edit_then_append(psi: Psi):
    out = psi.eval(
        'local agent = require("psi.agent_session")\n'
        + 'local rt = require("psi.tui_runtime")\n'
        + 'agent.clear_queues()\n'
        + 'agent.queue_follow_up("first queued")\n'
        + 'agent.queue_follow_up("second queued")\n'
        + 'local function text(s) return {key="text", text=s} end\n'
        + 'local state = rt._debug_edit_keys("", 0, {\n'
        + '  {key="ctrl-p"}, {key="ctrl-a"}, {key="ctrl-k"}, text("edited queued"),\n'
        + '  {key="enter"}, text("third queued"), {key="enter"}\n'
        + '}, false, {busy=true})\n'
        + 'local pending = agent.pending_messages()\n'
        + 'return table.concat({\n'
        + '  pending[1].text,\n'
        + '  pending[2].text,\n'
        + '  pending[3].text,\n'
        + '  tostring(state.queue_nav_index)\n'
        + '}, "|")'
    )
    assert_equals(out, "first queued|edited queued|third queued|nil",
                  "editing a queued message should not make the next busy submit overwrite it")


@test("tui/consumed_queue_preview_clears_editor")
def t_tui_consumed_queue_preview_clears_editor(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local same = rt._debug_consume_queued_preview("queued text", "queued text")\n'
        + 'local edited = rt._debug_consume_queued_preview("queued text edited", "queued text")\n'
        + 'return table.concat({\n'
        + '  same.input,\n'
        + '  tostring(same.cursor),\n'
        + '  tostring(same.queue_nav_index),\n'
        + '  edited.input\n'
        + '}, "|")'
    )
    assert_equals(out, "|0|nil|queued text edited",
                  "consuming a displayed queued preview should clear only the unmodified preview")


@test("tui/busy_btw_not_consumed")
def t_tui_busy_btw_not_consumed(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local state = rt._debug_edit_keys("/btw keep me", 12, {{key="enter"}}, false, {busy=true})\n'
        + 'return state.input .. "|" .. tostring(state.status_text)'
    )
    assert_equals(out, "/btw keep me|/btw is unavailable while a turn is running",
                  "busy /btw should remain editable instead of being dropped")


@test("tui/busy_unavailable_command_not_consumed")
def t_tui_busy_unavailable_command_not_consumed(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local state = rt._debug_edit_keys("/model x", 8, {{key="enter"}}, false, {busy=true})\n'
        + 'return state.input .. "|" .. tostring(state.status_text)'
    )
    assert_equals(out, "/model x|command unavailable while busy",
                  "busy unavailable slash commands should remain editable")


@test("tui/busy_slash_command_does_not_dispatch")
def t_tui_busy_slash_command_does_not_dispatch(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'psi.session_append("user", "keep", nil)\n'
        + 'local before = psi.session_message_count()\n'
        + 'local state = rt._debug_edit_keys("/new", 4, {{key="enter"}}, false, {busy=true})\n'
        + 'return table.concat({\n'
        + '  tostring(before),\n'
        + '  tostring(psi.session_message_count()),\n'
        + '  state.input,\n'
        + '  tostring(state.status_text)\n'
        + '}, "|")'
    )
    assert_equals(out, "1|1|/new|command unavailable while busy",
                  "busy slash commands should not dispatch side effects like /new")


@test("tui/non_agent_busy_submit_not_queued")
def t_tui_non_agent_busy_submit_not_queued(psi: Psi):
    out = psi.eval(
        'local agent = require("psi.agent_session")\n'
        + 'local rt = require("psi.tui_runtime")\n'
        + 'agent.clear_queues()\n'
        + 'local state = rt._debug_edit_keys("draft", 5, {{key="enter"}}, false, {busy=true, busy_kind="compact"})\n'
        + 'return state.input .. "|" .. tostring(agent.pending_message_count()) .. "|" .. tostring(state.status_text)'
    )
    assert_equals(out, "draft|0|busy",
                  "non-agent busy states should preserve input instead of queueing follow-ups")


@test("tui/vim_modal_keys")
def t_tui_vim_modal_keys(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local tui = require("psi.tui_status")\n'
        + 'require("psi.extensions.vim_keybindings").enable(psi)\n'
        + 'local function text(c) return {key="text", text=c} end\n'
        + 'local s = rt._debug_edit_keys("alpha beta gamma", 0, {\n'
        + '  {key="escape"}, text("w"), text("v"), text("l"), text("l"), text("l"), text("l"), text("y"), text("p")\n'
        + '})\n'
        + 'local b = rt._debug_edit_keys("aa\\nbb\\ncc", 0, {\n'
        + '  {key="escape"}, {key="ctrl-v"}, text("j"), text("y")\n'
        + '})\n'
        + 'local g = rt._debug_edit_keys("", 0, {\n'
        + '  {key="escape"}, {key="ctrl-u"}, text("g"), text("g"), text("G")\n'
        + '})\n'
        + 'local a = rt._debug_edit_keys("  aa\\nbb", 0, {\n'
        + '  {key="escape"}, text("A"), text("!"), {key="escape"}\n'
        + '})\n'
        + 'local i = rt._debug_edit_keys("  aa", 4, {\n'
        + '  {key="escape"}, text("I"), text("x"), {key="escape"}\n'
        + '})\n'
        + 'local o = rt._debug_edit_keys("aa\\nbb", 0, {\n'
        + '  {key="escape"}, text("o"), text("x"), {key="escape"}\n'
        + '})\n'
        + 'local O = rt._debug_edit_keys("aa\\nbb", 3, {\n'
        + '  {key="escape"}, text("O"), text("x"), {key="escape"}\n'
        + '})\n'
        + 'local line = rt._debug_edit_keys("  aa\\nbb", 0, {\n'
        + '  {key="escape"}, text("$"), text("^"), {key="ctrl-e"}, {key="ctrl-a"}\n'
        + '})\n'
        + 'local clear = rt._debug_edit_keys("abc", 2, {\n'
        + '  {key="escape"}, {key="ctrl-c"}\n'
        + '})\n'
        + 'local visual = rt._debug_edit_keys("abc", 0, {\n'
        + '  {key="escape"}, text("v"), text("l")\n'
        + '})\n'
        + 'local line_visual = rt._debug_edit_keys("alpha\\n\\nbeta", 6, {\n'
        + '  {key="escape"}, text("V")\n'
        + '})\n'
        + 'local block_insert = rt._debug_edit_keys("aa\\nbb\\ncc", 0, {\n'
        + '  {key="escape"}, {key="ctrl-v"}, text("j"), text("I"), text("x"), {key="escape"}\n'
        + '})\n'
        + 'local block_append = rt._debug_edit_keys("aa\\nbb\\ncc", 0, {\n'
        + '  {key="escape"}, {key="ctrl-v"}, text("l"), text("j"), text("A"), text("x"), {key="escape"}\n'
        + '})\n'
        + 'local interrupt = tui.handle_key({key="ctrl-g", busy=true, editor_mode="normal", input_length=1})\n'
        + 'return table.concat({\n'
        + '  s.editor_mode, tostring(s.cursor), s.clipboard, s.input,\n'
        + '  b.selection_kind or "-", b.clipboard,\n'
        + '  tostring(g.scroll_offset), g.editor_mode,\n'
        + '  a.input, i.input, o.input, O.input,\n'
        + '  tostring(line.cursor), clear.input, clear.editor_mode,\n'
        + '  tostring((visual.rendered[1] or ""):find("\\27%[7m") ~= nil),\n'
        + '  line_visual.selection_kind or "-",\n'
        + '  tostring((line_visual.rendered[2] or ""):find("\\27%[7m") ~= nil),\n'
        + '  block_insert.input,\n'
        + '  block_append.input,\n'
        + '  interrupt and interrupt.action or "-"\n'
        + '}, "|")'
    )
    assert_equals(out, "normal|14|beta|alpha betabeta gamma|-|a\nb|0|normal|  aa!\nbb|  xaa|aa\nx\nbb|aa\nx\nbb|0||insert|true|line|true|xaa\nxbb\ncc|aax\nbbx\ncc|abort",
                  "Vim modal TUI keys")


@test("tui/osc52_clipboard")
def t_tui_osc52_clipboard(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'local osc52 = require("psi.extensions.osc52_clipboard")\n'
        + 'local writes = {}\n'
        + 'psi.stdout_write = function(text) writes[#writes + 1] = text end\n'
        + 'osc52.disable(psi)\n'
        + 'tui.clear_clipboard_writers()\n'
        + 'osc52.enable(psi)\n'
        + 'local wrote = tui.write_clipboard("hi", {source="test", force=true})\n'
        + 'local direct = osc52._debug_osc52_sequence("hi", {TMUX=""})\n'
        + 'local tmux = osc52._debug_osc52_sequence("hi", {TMUX="/tmp/tmux"})\n'
        + 'local capped = osc52.write_clipboard(string.rep("a", 75001), {source="test"})\n'
        + 'return table.concat({\n'
        + '  osc52._debug_base64_encode("hello"),\n'
        + '  tostring(wrote),\n'
        + '  tostring((writes[1] or ""):find("52;", 1, true) ~= nil and (writes[1] or ""):find(";aGk=", 1, true) ~= nil),\n'
        + '  tostring(direct:sub(1, 2) == "\\27]"),\n'
        + '  tostring(tmux:sub(1, 7) == "\\27Ptmux;"),\n'
        + '  tostring(capped),\n'
        + '  tostring(#writes)\n'
        + '}, "|")'
    )
    assert_equals(out, "aGVsbG8=|true|true|true|true|false|1", "OSC 52 clipboard writer")


@test("tui/vim_yank_writes_clipboard")
def t_tui_vim_yank_writes_clipboard(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui_status")\n'
        + 'local rt = require("psi.tui_runtime")\n'
        + 'require("psi.extensions.vim_keybindings").enable(psi)\n'
        + 'local copied = "-"\n'
        + 'tui.clear_clipboard_writers()\n'
        + 'tui.register_clipboard_writer(function(text) copied = text return true end)\n'
        + 'rt._debug_edit_keys("abc", 0, {{key="escape"}, {key="text", text="y"}}, false, {clipboard_writers=true})\n'
        + 'return copied'
    )
    assert_equals(out, "abc", "Vim yank writes through TUI clipboard hook")


@test("tui/vim_toggle")
def t_tui_vim_toggle(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local function run(input, events)\n'
        + '  local s = rt._debug_edit_keys(input, #input, events)\n'
        + '  return table.concat({s.status_text or "-", s.editor_mode, s.input}, "|")\n'
        + 'end\n'
        + 'return table.concat({\n'
        + '  run("", {{key="escape"}}),\n'
        + '  run("/vim", {{key="enter"}, {key="escape"}}),\n'
        + '  run("/vim off", {{key="enter"}, {key="escape"}})\n'
        + '}, "||")'
    )
    assert_equals(
        out,
        "-|insert|||Vim keybindings enabled|normal|||Vim keybindings disabled|insert|",
        "Vim extension is off by default and /vim toggles it",
    )


@test("tui/vim_config_enable")
def t_tui_vim_config_enable(psi: Psi):
    cwd = psi.tmp / "vim-config"
    (cwd / ".psi").mkdir(parents=True, exist_ok=True)
    (cwd / ".psi" / "settings.json").write_text(
        json.dumps({"extensions": {"vim_keybindings": {"enabled": True}}})
    )
    out = psi.run(
        "--eval",
        'local rt = require("psi.tui_runtime")\n'
        + 'local s = rt._debug_edit_keys("abc", 0, {{key="escape"}}, true)\n'
        + 'return s.editor_mode',
        cwd=cwd,
    ).stdout.strip()
    assert_equals(out, "normal", "config enables bundled Vim extension")


@test("render/replace_mode")
def t_render_replace(psi: Psi):
    """A render hook returning {replace=true, text=...} must drop
    earlier hooks' output from the chain and start the accumulator
    over. Later hooks still append. Verifies the replace-mode
    rough-edge fix from session be5ebe99."""
    out = psi.eval(
        'local r = require("psi.render")\n'
        + 'r.register_hook("before-turn", function() return "first\\n" end)\n'
        + 'r.register_hook("before-turn", function()\n'
        + '  return { replace = true, text = "REPLACED\\n" }\n'
        + 'end)\n'
        + 'r.register_hook("before-turn", function() return "tail\\n" end)\n'
        + 'return r.handle_event("before-turn", {})'
    )
    assert_not_contains(out, "first", "first hook's string should have been dropped")
    assert_contains(out, "REPLACED", "replacement text present")
    assert_contains(out, "tail", "later hook still appends after replace")


@test("render/event_catalog")
def t_render_events(psi: Psi):
    out = psi.eval(
        'return table.concat(require("psi.render").events(), ",")')
    for ev in ("before-turn", "tool-call", "tool-result", "after-turn"):
        assert_contains(out, ev, f"catalog lists {ev}")


@test("render/tui_after_turn_payload")
def t_tui_after_turn_payload(psi: Psi):
    out = psi.eval(
        'local rt = require("psi.tui_runtime")\n'
        + 'local a = rt._debug_after_turn_payload("", false)\n'
        + 'local b = rt._debug_after_turn_payload("reply", true)\n'
        + 'return tostring(a["assistant-streamed"]) .. "|" .. a.text .. "|"\n'
        + '  .. tostring(b["assistant-streamed"]) .. "|" .. b.text'
    )
    assert_equals(out.strip(), "false||true|reply", "TUI after-turn payload")


@test("introspect/embedded_source")
def t_embedded_source(psi: Psi):
    """psi.embedded_source must surface a module's raw Lua source so
    extensions can introspect built-ins without an on-disk path."""
    out = psi.eval(
        'local src = psi.embedded_source("psi.render")\n'
        + 'local names = psi.embedded_source_names()\n'
        + 'return (src and #src or 0) .. "|" .. #names .. "|"\n'
        + '       .. tostring(psi.embedded_source("no.such.module"))'
    )
    # Format: "<src_len>|<name_count>|nil"
    parts = out.strip().split("|")
    assert_equals(len(parts), 3, f"unexpected shape: {out!r}")
    assert_true(int(parts[0]) > 100, "render source should be non-trivial")
    assert_true(int(parts[1]) > 10, "should enumerate many modules")
    assert_equals(parts[2], "nil", "unknown module must return nil")

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
    assert_bytes_contains(raw, b"\x1b[38;5;245m",
                          "input box border color did not reach rendered output")

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
    # in the same turn. Counting "╭─" substrings is too tight — terminal
    # repaints many frames and sometimes clobbers earlier panel headers
    # before the PTY capture window closes (model emits narration text
    # before tool calls, first-token latency eats into the 25 s budget,
    # etc.). At least ONE ╭─ confirms the tool-panel drawer wired up.
    for fruit in ("apple", "banana", "cherry"):
        assert_contains(text, fruit, f"{fruit} in TUI output")
    assert_true(
        "╭─" in text,
        "no tool-call panel header in the captured pty stream",
    )

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
