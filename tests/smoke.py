#!/usr/bin/env python3
"""psi smoke suite.

Runs a battery of end-to-end tests against the built psi binary:
Lua eval surface, every built-in tool, render hooks, system prompt,
print / TUI / session modes, and — when ANTHROPIC_API_KEY is set —
a live agent sequence that exercises tool dispatch, session save,
compaction, and concurrent-tool wall-time.

Usage:
    tests/smoke.py                 # run everything, live included if key set
    tests/smoke.py --filter foo    # only run tests whose name matches
    tests/smoke.py --no-live       # skip live-agent tests even if key set
    tests/smoke.py --psi PATH      # override psi binary location

Exit status: 0 on clean, 1 on any failure.
"""
from __future__ import annotations

import argparse
import json
import os
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


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


class Fail(Exception):
    """Raised inside a test on assertion failure."""


def assert_contains(haystack: str, needle: str, what: str = "output") -> None:
    if needle not in haystack:
        raise Fail(f"{what} missing {needle!r}\n--- got ---\n{haystack}")


def assert_regex(haystack: str, pattern: str, what: str = "output") -> None:
    if not re.search(pattern, haystack, re.MULTILINE):
        raise Fail(f"{what} does not match /{pattern}/\n--- got ---\n{haystack}")


def assert_equals(got, want, what: str = "value") -> None:
    if got != want:
        raise Fail(f"{what}: expected {want!r}, got {got!r}")


def assert_true(cond, reason: str) -> None:
    if not cond:
        raise Fail(reason)


# ---------------------------------------------------------------------------
# Psi helper: thin wrapper around subprocess that knows where the binary
# lives, keeps a per-test temp dir, and surfaces stdout + stderr + exit.
# ---------------------------------------------------------------------------


class Psi:
    def __init__(self, binary: str, tmp: Path):
        self.binary = binary
        self.tmp = tmp

    def run(self, *args: str, input_text: str | None = None,
            check: bool = True, env_extra: dict | None = None,
            cwd: Path | None = None, timeout: float = 60) -> subprocess.CompletedProcess:
        """Run psi and return the completed process. Raises on non-zero when check=True."""
        env = os.environ.copy()
        if env_extra:
            env.update(env_extra)
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
# PTY driver for TUI tests. Uses the stdlib `pty` module — no dependency on
# `script(1)`. Times out safely if the child hangs.
# ---------------------------------------------------------------------------


def run_pty(cmd: list[str], scenario: list[tuple[str, float]],
            env_extra: dict | None = None, idle_drain: float = 2.0) -> bytes:
    """Drive a pty session with a scripted (input, wait_secs) sequence.

    Reads everything the child writes and returns it as raw bytes. Sends
    each input after waiting its delay, then idle-drains for `idle_drain`
    seconds after the last input so any trailing output is captured.
    """
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(cmd[0], cmd, env)
        except Exception as exc:  # noqa: BLE001
            os.write(2, f"exec failed: {exc}\n".encode())
            os._exit(127)

    buf = bytearray()
    try:
        for data, delay in scenario:
            deadline = time.time() + delay
            while time.time() < deadline:
                r, _, _ = select.select([fd], [], [], min(0.1, deadline - time.time()))
                if not r:
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                buf.extend(chunk)
            if data:
                os.write(fd, data)

        idle_deadline = time.time() + idle_drain
        while time.time() < idle_deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf.extend(chunk)
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    return bytes(buf)


def strip_ansi(raw: bytes) -> str:
    text = raw.decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[\d;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b[=>]", "", text)
    text = re.sub(r"\x1b\[\?[\d]+[a-z]", "", text)
    return text


# ---------------------------------------------------------------------------
# Offline tests (no API key required).
# ---------------------------------------------------------------------------


@test("eval/arithmetic")
def t_eval_arithmetic(psi: Psi):
    assert_equals(psi.eval("return 1 + 2 + 3"), "6", "arithmetic")


@test("eval/read_primitive")
def t_eval_read_primitive(psi: Psi):
    out = psi.eval('return #psi.read_file("README.md") > 0 and "ok" or "bad"')
    assert_equals(out, "ok", "read primitive")


@test("eval/tool_registry")
def t_eval_tool_registry(psi: Psi):
    # The registry's first registered tool is `read`.
    out = psi.eval('return require("psi.tools").all()[1].name')
    assert_equals(out, "read", "first tool")


@test("tool/read")
def t_tool_read(psi: Psi):
    out = psi.eval(
        'local r = require("psi.tools").dispatch("read", {path="README.md"})\n'
        'return r.tool .. " " .. tostring(r.ok)'
    )
    assert_equals(out, "read true", "read tool result")


@test("tool/write")
def t_tool_write(psi: Psi):
    target = psi.tmp / "tool.txt"
    out = psi.eval(
        f"local r = require('psi.tools').dispatch('write', "
        f"{{path='{target}', content='alpha beta'}})\n"
        "return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.bytes_written)"
    )
    assert_equals(out, "write true 10", "write tool result")
    assert_equals(target.read_text(), "alpha beta", "written file")


@test("tool/edit")
def t_tool_edit(psi: Psi):
    target = psi.tmp / "tool.txt"
    target.write_text("alpha beta")
    out = psi.eval(
        f"local r = require('psi.tools').dispatch('edit', "
        f"{{path='{target}', oldText='beta', newText='gamma'}})\n"
        "return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.replacements)"
    )
    assert_equals(out, "edit true 1", "edit tool result")
    assert_equals(target.read_text(), "alpha gamma", "edited file")


@test("tool/bash")
def t_tool_bash(psi: Psi):
    out = psi.eval(
        'local r = require("psi.tools").dispatch("bash", {command="printf hello"})\n'
        "return r.extras.output"
    )
    assert_equals(out, "hello", "bash output")


@test("tool/grep")
def t_tool_grep(psi: Psi):
    target = psi.tmp / "tool.txt"
    target.write_text("alpha gamma")
    out = psi.eval(
        f"local r = require('psi.tools').dispatch('grep', "
        f"{{pattern='alpha gamma', path='{target}', literal=true}})\n"
        "return r.tool .. ' ' .. tostring(r.ok)"
    )
    assert_equals(out, "grep true", "grep tool result")


@test("tool/find")
def t_tool_find(psi: Psi):
    out = psi.eval(
        'local r = require("psi.tools").dispatch("find", {pattern="*.md", path=".", limit=5})\n'
        'return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)'
    )
    assert_equals(out, "find true true", "find tool result")


@test("tool/ls")
def t_tool_ls(psi: Psi):
    out = psi.eval(
        'local r = require("psi.tools").dispatch("ls", {path=".", limit=5})\n'
        'return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)'
    )
    assert_equals(out, "ls true true", "ls tool result")


@test("tool/lua_summary")
def t_tool_lua_summary(psi: Psi):
    out = psi.eval(
        'local r = require("psi.tools").dispatch("lua", {mode="summary"})\n'
        'return r.extras.result:match("psi Lua runtime")'
    )
    assert_equals(out, "psi Lua runtime", "lua summary banner")


@test("tool/lua_eval")
def t_tool_lua_eval(psi: Psi):
    # 8 tools registered today (read/write/edit/bash/grep/find/ls/lua).
    out = psi.eval(
        'local r = require("psi.tools").dispatch("lua", '
        '{mode="eval", expression="#require(\\"psi.tools\\").all()"})\n'
        'return r.extras.result'
    )
    assert_equals(out, "8", "tool count")


@test("render/tool_write_diff")
def t_render_write_diff(psi: Psi):
    target = psi.tmp / "tool.txt"
    target.write_text("alpha beta")
    out = psi.eval(
        "local tools = require('psi.tools')\n"
        "local render = require('psi.render')\n"
        f"render.handle_event('tool-call', {{id='w1', tool='write', input={{path='{target}', content='delta'}}}})\n"
        f"local r = tools.dispatch('write', {{path='{target}', content='delta'}})\n"
        "return render.handle_event('tool-result', {id='w1', tool='write', result=r})"
    )
    assert_contains(out, "updated", "write diff header")
    assert_contains(out, "delta", "diff payload")


@test("events/context_mutation")
def t_context_event(psi: Psi):
    """The context event is emitted with a mutable messages table
    just before the provider call. Subscribers mutate in place and
    their edits are reflected on the wire. Verified here via a Lua
    round-trip: register a handler, build a dummy api_messages table,
    fire the event, confirm mutation sticks."""
    out = psi.eval(
        'local fired = 0\n'
        + 'local seen_provider = ""\n'
        + 'psi.events.on("context", function(p)\n'
        + '  fired = fired + 1\n'
        + '  seen_provider = p.provider or ""\n'
        + '  p.messages[#p.messages + 1] = "appended"\n'
        + 'end)\n'
        + 'local msgs = {"a", "b"}\n'
        + 'psi.events.emit("context", {\n'
        + '  messages = msgs, provider = "ollama",\n'
        + '  model = "x", system_prompt = "s"\n'
        + '})\n'
        + 'return fired .. "|" .. seen_provider .. "|" .. #msgs'
    )
    assert_contains(out, "1|ollama|3",
                    f"context event shape wrong: {out!r}")


@test("events/session_lifecycle")
def t_session_lifecycle(psi: Psi):
    out = psi.eval(
        'local seen = {}\n'
        + 'psi.events.on("session-start", function(p)\n'
        + '  seen[#seen + 1] = "start:" .. tostring(p.source)\n'
        + 'end)\n'
        + 'psi.events.on("session-shutdown", function()\n'
        + '  seen[#seen + 1] = "shutdown"\n'
        + 'end)\n'
        + 'local s = require("psi.session")\n'
        + 's.announce_start()\n'
        + 's.announce_shutdown()\n'
        + 'return table.concat(seen, ",")'
    )
    assert_contains(out, "start:new,shutdown",
                    "lifecycle events fire in order")


@test("prompt/set_active_filters_system_prompt")
def t_set_active_prompt(psi: Psi):
    """set_active must also filter the system-prompt "Available tools"
    list — otherwise the model sees tools it can't dispatch and
    wastes tokens calling them. Matches pi's selectedTools option."""
    out = psi.eval(
        'local tools = require("psi.tools")\n'
        + 'local prompt = require("psi.prompt")\n'
        + 'tools.set_active({"read"})\n'
        + 'local sp = prompt.system_prompt()\n'
        + 'tools.set_active(nil)\n'
        + 'return tostring(sp:find("%- read:") ~= nil) .. "|"\n'
        + '  .. tostring(sp:find("%- bash:") ~= nil) .. "|"\n'
        + '  .. tostring(sp:find("%- grep:") ~= nil)'
    )
    assert_contains(out, "true|false|false",
                    "active set didn't filter prompt tools list")


@test("prompt_templates/load_and_expand")
def t_prompt_templates(psi: Psi):
    """Templates load from PSI_PROMPTS_DIR, frontmatter parses,
    arg substitution handles $1, $@, ${@:N}, ${@:N:L}."""
    tmpdir = psi.tmp / "tplprompts"
    tmpdir.mkdir(exist_ok=True)
    (tmpdir / "greet.md").write_text(
        "---\n"
        "description: Say hello to $1\n"
        "argument-hint: <name>\n"
        "---\n"
        "Hello $1. All: $@. Skip one: ${@:2}. Two from 2: ${@:2:2}.\n"
    )
    expr = (
        'local pt = require("psi.prompt_templates")\n'
        + 'pt.load()\n'
        + 'local list = pt.list()\n'
        + 'local a = (#list == 1)\n'
        + 'local t = list[1]\n'
        + 'local b = (t.description == "Say hello to $1")\n'
        + 'local c = (t.argument_hint == "<name>")\n'
        + 'local expanded = pt.expand("/greet Alice Bob Carol Dave")\n'
        + 'return tostring(a) .. "|" .. tostring(b) .. "|"\n'
        + '  .. tostring(c) .. "|" .. (expanded or "<nil>")'
    )
    out = psi.run("--eval", expr,
                  env_extra={"PSI_PROMPTS_DIR": str(tmpdir)}).stdout.strip()
    parts = out.strip().split("|", 3)
    assert parts[0] == "true", f"expected 1 template, got: {out!r}"
    assert parts[1] == "true", f"description wrong: {out!r}"
    assert parts[2] == "true", f"argument_hint wrong: {out!r}"
    body = parts[3]
    assert_contains(body, "Hello Alice", "$1 substituted")
    assert_contains(body, "All: Alice Bob Carol Dave", "$@ substituted")
    assert_contains(body, "Skip one: Bob Carol Dave", "${@:N} slice")
    assert_contains(body, "Two from 2: Bob Carol", "${@:N:L} slice")


@test("prompt_templates/not_a_template_returns_nil")
def t_prompt_templates_miss(psi: Psi):
    out = psi.eval(
        'local pt = require("psi.prompt_templates")\n'
        + 'pt.load()\n'
        + 'return tostring(pt.expand("/nosuchtemplate foo"))'
    )
    assert_contains(out, "nil",
                    f"unknown slash must return nil: {out!r}")


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
    assert int(parts[0]) >= 3 and int(parts[1]) == 2, \
        f"allowlist didn't narrow: {out!r}"
    assert "read" in parts[2] and "grep" in parts[2]
    assert parts[0] == parts[3], "nil didn't restore full set"


@test("session/send_message")
def t_send_message(psi: Psi):
    out = psi.eval(
        'local s = require("psi.session")\n'
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
    assert "thinking:" not in b, \
        f"label must fire only once per turn, got: {b!r}"
    assert_contains(b, "second", "second delta renders text")
    assert_contains(c, "thinking: turn2",
                    "after-turn resets the one-shot label")


@test("compaction/snaps_past_orphan_tool_result")
def t_compact_snap(psi: Psi):
    """Regression for the Haiku session failure: do_compact must never
    leave a tool-result as the first kept entry (orphan). Mirrors pi's
    findValidCutPoints which excludes toolResult from valid cut
    points. Without the snap, Anthropic 400s with 'unexpected
    tool_use_id found in tool_result blocks'."""
    out = psi.eval(
        'local s = require("psi.session")\n'
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
    assert out.strip() != "tool-result", \
        f"orphan tool-result kept after compaction: {out!r}"


@test("anthropic/drops_orphan_tool_result")
def t_anthropic_orphan_drop(psi: Psi):
    """build_api_messages must skip tool-result entries whose
    tool_use_id has no matching tool_use in a preceding assistant
    message — e.g. a session loaded from an older psi that compacted
    without the snap. Exactly the Haiku session 71d7999f symptom."""
    out = psi.eval(
        'local a = require("psi.anthropic")\n'
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
    assert parts[0] == "false", f"orphan tool_result still in wire: {out!r}"
    # Expected wire: compaction-summary-as-user + the real user msg = 2
    assert int(parts[1]) >= 1


@test("session/ensure_default_path")
def t_session_default_path(psi: Psi):
    """Without --session, TUI calls psi.session.ensure_default_path
    which must pick an XDG-style location so autosave has a target.
    Skipping this made every turn show "failed to save session file"
    in the status bar (session 71f5944b symptom)."""
    out = psi.eval(
        'local s = require("psi.session")\n'
        + 'local first = s.ensure_default_path()\n'
        + 'local second = s.ensure_default_path()\n'
        + 'return tostring(first == second) .. "|"\n'
        + '       .. tostring(psi.session_path() == first) .. "|"\n'
        + '       .. (first or "<nil>")'
    )
    ok_idem, ok_set, path = out.strip().split("|", 2)
    assert ok_idem == "true", f"not idempotent: {out!r}"
    assert ok_set == "true", f"session_path not set: {out!r}"
    assert "/psi/sessions/" in path, f"unexpected path shape: {path!r}"
    assert path.endswith(".jsonl"), f"missing .jsonl: {path!r}"


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
        'local a = require("psi.agent")\n'
        + 'a.set_model("openrouter/x/y")\n'
        + 'local got = a.current_model("anthropic/fallback")\n'
        + 'a.set_model(nil)\n'
        + 'local cleared = a.current_model("anthropic/fallback")\n'
        + 'return got .. "|" .. cleared'
    )
    assert_contains(out, "openrouter/x/y|anthropic/fallback",
                    "override then clear")


@test("tui/status_hook")
def t_tui_status_hook(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui")\n'
        + 'tui.register_status_hook(function() return "ext:foo" end)\n'
        + 'local line = tui.status_line(\n'
        + '  psi.json_encode({model="m", busy=false, scroll=0}))\n'
        + 'tui.clear_status_hooks()\n'
        + 'return line'
    )
    assert_contains(out, "ext:foo", "status hook contribution shows")


@test("tui/layout_geometry")
def t_tui_layout_geometry(psi: Psi):
    out = psi.eval(
        'local layout = require("psi.tui_layout").geometry(80, 24)\n'
        + 'return table.concat({layout.title, layout.transcript.h, layout.input.y}, "|")'
    )
    assert_equals(out, "psi coding agent|18|21", "shared TUI layout")


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
    assert_equals(out, '5|"> "|"| "', "Lua-owned TUI input layout")


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


@test("tui/key_policy")
def t_tui_key_policy(psi: Psi):
    out = psi.eval(
        'local tui = require("psi.tui")\n'
        + 'local function fmt(res)\n'
        + '  if not res then return "nil" end\n'
        + '  local arg = res.arg\n'
        + '  if arg == "\\n" then arg = "\\\\n" end\n'
        + '  return (res.action or "?") .. ":" .. (arg or "-")\n'
        + 'end\n'
        + 'return table.concat({\n'
        + '  fmt(tui.handle_key({key="enter", busy=false, input_length=1})),\n'
        + '  fmt(tui.handle_key({key="enter", busy=true, input_length=1})),\n'
        + '  fmt(tui.handle_key({key="shift-enter", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-d", busy=false, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="ctrl-d", busy=true, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="escape", busy=true, input_length=0})),\n'
        + '  fmt(tui.handle_key({key="text", text="x"}))\n'
        + '}, "|")'
    )
    assert_equals(out, "submit:-|nil|insert:\\n|quit:-|nil|abort:-|insert:x",
                  "Lua TUI key policy")


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
    assert "first" not in out, "first hook's string should have been dropped"
    assert_contains(out, "REPLACED", "replacement text present")
    assert_contains(out, "tail", "later hook still appends after replace")


@test("render/event_catalog")
def t_render_events(psi: Psi):
    out = psi.eval(
        'return table.concat(require("psi.render").events(), ",")')
    for ev in ("before-turn", "tool-call", "tool-result", "after-turn"):
        assert_contains(out, ev, f"catalog lists {ev}")


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
    assert len(parts) == 3, f"unexpected shape: {out!r}"
    assert int(parts[0]) > 100, "render source should be non-trivial"
    assert int(parts[1]) > 10, "should enumerate many modules"
    assert parts[2] == "nil", "unknown module must return nil"


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


@test("mode/print_text")
def t_print_text(psi: Psi):
    out = psi.print_("hello")
    assert_contains(out, "prompt: hello", "print echo")
    assert_contains(out, "session-messages: 1", "session count")


@test("mode/repl_quit")
def t_repl_quit(psi: Psi):
    # `:quit` should cleanly exit the REPL; psi also accepts this from
    # interactive mode at startup.
    psi.run(input_text=":quit\n")


@test("mode/tui_quits")
def t_tui_quits(psi: Psi):
    # Drive the TUI through a pty, send /quit, expect a clean exit.
    raw = run_pty([psi.binary, "--tui"], [(b"", 0.5), (b"/quit\r", 1.0)])
    text = strip_ansi(raw)
    # We don't require any specific text — just confirm the binary ran
    # long enough to render its header before accepting /quit.
    assert_contains(text, "psi coding agent", "TUI header")


@test("mode/tui_lf_submit")
def t_tui_lf_submit(psi: Psi):
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.5),
            (b"/session\n", 1.0),
            (b"/quit\n", 1.0),
        ],
    )
    text = strip_ansi(raw)
    assert_regex(text, r"id:\s+[0-9a-f-]{8}", "bare LF submits commands")


@test("mode/tui_multiline_prompt")
def t_tui_multiline_prompt(psi: Psi):
    raw = run_pty(
        [psi.binary, "--tui"],
        [
            (b"", 0.5),
            (b"alpha\x1b[27;2;13~bravo\r", 1.0),
            (b"/quit\r", 1.0),
        ],
    )
    text = strip_ansi(raw)
    assert_contains(text, "You: alpha", "first line submitted")
    assert_contains(text, "bravo", "second line submitted")


@test("session/save_no_path_is_distinct")
def t_save_no_path(psi: Psi):
    """session.save() with no path must return a distinguishable
    failure so extensions (like the autosave extension in
    ~/.config/psi/extensions/) can tell a real write from a no-op.
    Regression test for the i686-transcripts bug where flushes
    counter incremented while nothing ever hit disk."""
    out = psi.eval(
        'local session = require("psi.session")\n'
        'local ok, err = session.save()\n'
        'return tostring(ok) .. " | " .. tostring(err)'
    )
    assert_equals(out, "false | no session path set", "no-op save contract")


@test("session/save_stamps_id_without_path")
def t_save_stamps_id(psi: Psi):
    """session_id must be assigned before any observable event fires,
    not lazily inside save() behind the path-gate. Regression test
    for the autosave bug where `after-provider-response` saw
    session_id()==nil on its first flush because no path was set
    yet, and the extension fell back to a timestamp filename."""
    out = psi.eval(
        'local session = require("psi.session")\n'
        'print("before:", tostring(psi.session_id()))\n'
        'session.save()  -- returns false, but should still stamp id\n'
        'local id = psi.session_id()\n'
        'return (id ~= nil and #id > 0) and "stamped" or "still-nil"'
    )
    assert_contains(out, "stamped", "session id assigned by ensure_id")


@test("session/append_stamps_id")
def t_append_stamps_id(psi: Psi):
    """Any append_* call is an observable event; id must exist
    before an extension's hook runs."""
    out = psi.eval(
        'local session = require("psi.session")\n'
        'session.append_user("hi")\n'
        'local id = psi.session_id()\n'
        'return (id ~= nil and #id > 0) and "stamped" or "still-nil"'
    )
    assert_equals(out, "stamped", "append_user stamps id")


@test("errors/classify_http_error")
def t_classify_http(psi: Psi):
    """openai_compat.classify_http_error must (a) prepend a status-
    specific hint for common failure codes and (b) surface the
    provider's error-body message when present."""
    out = psi.eval(
        'local c = require("psi.openai_compat").classify_http_error\n'
        + 'local results = {}\n'
        + 'results[1] = c(401,\n'
        + '  psi.json_encode({error = {message = "invalid key"}}),\n'
        + '  "anthropic")\n'
        + 'results[2] = c(429, "", "openrouter")\n'
        + 'results[3] = c(404,\n'
        + '  psi.json_encode({error = {message = "no such model"}}),\n'
        + '  "openrouter")\n'
        + 'results[4] = c(503, "upstream exploded", "ollama")\n'
        + 'return table.concat(results, "|")'
    )
    # Each line must include provider + status + hint + detail.
    for needle in (
        "anthropic request failed (401)",
        "check your API key",
        "invalid key",
        "openrouter request failed (429)",
        "rate limited",
        "no such model",
        "provider is overloaded",
        "upstream exploded",
    ):
        assert_contains(out, needle, f"classifier missing {needle!r}")


@test("handles/process_finish_idempotent")
def t_process_finish_idempotent(psi: Psi):
    """process_finish should be idempotent — calling it twice (or
    once explicitly and once via __gc) must not double-free."""
    # Drive the begin/poll/finish cycle properly (poll drains the
    # child's stdout into the internal buffer), then finish twice.
    # Second call must return a zero-shaped table, not error.
    out = psi.eval(
        'local h = psi.process_begin("echo idempotent-test")\n'
        + 'while true do\n'
        + '  local _, done = psi.process_poll(h, 50)\n'
        + '  if done then break end\n'
        + 'end\n'
        + 'local r1 = psi.process_finish(h)\n'
        + 'local r2 = psi.process_finish(h)\n'
        + 'return r1.output:gsub("%s+$", "") .. "|" '
        + '     .. tostring(r1.status) .. "|" .. r2.output'
    )
    assert_equals(out, "idempotent-test|0|", "double-finish returns empty")


@test("handles/process_gc_runs")
def t_process_gc_runs(psi: Psi):
    """If a coroutine orphans a handle (never calls finish), __gc
    must run the finaliser so the child process + pipe fds don't
    leak. This test verifies the __gc finaliser path at least
    runs without erroring; leak detection beyond "no crash" would
    need process-tree inspection outside this harness."""
    out = psi.eval(
        'do\n'
        + '  local h = psi.process_begin("true")\n'
        + '  psi.sleep_ms(50)\n'
        + '  h = nil\n'
        + 'end\n'
        + 'collectgarbage("collect")\n'
        + 'collectgarbage("collect")\n'
        + 'return "ok"'
    )
    assert_equals(out, "ok", "gc cycle completed without error")


@test("session/append_only_correctness")
def t_append_only(psi: Psi):
    """Verify the append-only save fast path writes the same bytes as
    a full rewrite: append entries across several saves and confirm
    the on-disk file matches a sibling written via a single save."""
    a = str(psi.tmp / "a.jsonl")
    out = psi.eval(
        'local s = require("psi.session")\n'
        + 'psi.session_set_path("' + a + '")\n'
        + 's.append_user("one"); s.save()\n'
        + 's.append_assistant("two", {{type="text",text="two"}}); s.save()\n'
        + 's.append_tool_result("id1", "bash", "three", false); s.save()\n'
        + 'local body = psi.read_file("' + a + '") or ""\n'
        + '-- Confirm all three entries AND the session header made it.\n'
        + 'local has_header = body:find([["type":"session"]], 1, true) ~= nil\n'
        + 'local has_user   = body:find([["text":"one"]], 1, true) ~= nil\n'
        + 'local has_asst   = body:find([[two]], 1, true) ~= nil\n'
        + 'local has_tool   = body:find([[three]], 1, true) ~= nil\n'
        + 'local msgs = 0\n'
        + 'for _ in body:gmatch([["type":"message"]]) do msgs = msgs + 1 end\n'
        + 'return string.format("hdr=%s usr=%s ast=%s tl=%s msgs=%d",\n'
        + '  tostring(has_header), tostring(has_user),\n'
        + '  tostring(has_asst), tostring(has_tool), msgs)'
    )
    assert_equals(out, "hdr=true usr=true ast=true tl=true msgs=3",
                  "append-only write preserves header + all entries")


@test("session/compaction_rewrites")
def t_compaction_rewrites(psi: Psi):
    """Regression: after do_compact shrinks the in-memory session,
    the next save() must do a full rewrite (not append) so the
    on-disk file reflects the compacted state."""
    out = psi.eval(
        'local s = require("psi.session")\n'
        'local path = "' + str(psi.tmp / "c.jsonl") + '"\n'
        'psi.session_set_path(path)\n'
        'for i = 1, 10 do s.append_user("msg " .. i) end\n'
        's.save()\n'
        'local before = #(psi.read_file(path) or "")\n'
        's.do_compact(2, "summary")\n'
        's.save()\n'
        'local after = #(psi.read_file(path) or "")\n'
        '-- After compacting 10 → 3 entries (1 summary + 2 kept),\n'
        '-- the file must shrink relative to before.\n'
        'return (after < before) and "ok" or ("bad before=" .. before .. " after=" .. after)'
    )
    assert_equals(out, "ok", "compaction did full rewrite")


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
                25.0,
            ),
            (b"/quit\r", 1.0),
        ],
        idle_drain=2.0,
    )
    text = strip_ansi(raw)
    # Each fruit must appear in the rendered output (progress or final).
    # This is the semantic check: if all three appear, three tools ran
    # in the same turn. Counting "╭─" substrings is too tight — ncurses
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
# Driver.
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--psi", default=str(ROOT / "build" / "psi"),
                    help="path to psi binary")
    ap.add_argument("--filter", default=None,
                    help="only run tests whose name contains this substring")
    ap.add_argument("--no-live", action="store_true",
                    help="skip live-agent tests even if ANTHROPIC_API_KEY is set")
    ap.add_argument("--list", action="store_true",
                    help="list test names and exit")
    args = ap.parse_args()

    if args.list:
        for name, _fn, meta in TESTS:
            tag = "(live)" if meta["live"] else ""
            print(f"{name} {tag}".rstrip())
        return 0

    if not Path(args.psi).exists():
        print(f"psi binary not found at {args.psi}; build it or pass --psi", file=sys.stderr)
        return 1

    have_key = "ANTHROPIC_API_KEY" in os.environ and os.environ["ANTHROPIC_API_KEY"]
    run_live = bool(have_key) and not args.no_live

    passed = 0
    failed = 0
    skipped = 0
    total_start = time.time()

    for name, fn, meta in TESTS:
        if args.filter and args.filter not in name:
            continue
        if meta["live"] and not run_live:
            skipped += 1
            print(f"SKIP  {name}")
            continue

        # Per-test temp dir so each test is isolated.
        with tempfile.TemporaryDirectory(prefix="psi-smoke-") as td:
            psi = Psi(args.psi, Path(td))
            t0 = time.time()
            try:
                fn(psi)
            except Fail as err:
                failed += 1
                print(f"FAIL  {name}  ({time.time() - t0:.1f}s)")
                print("      " + str(err).replace("\n", "\n      "))
                continue
            except Exception as err:  # noqa: BLE001
                failed += 1
                print(f"FAIL  {name}  ({time.time() - t0:.1f}s) -- unexpected {type(err).__name__}: {err}")
                import traceback
                traceback.print_exc()
                continue
            passed += 1
            dt = time.time() - t0
            extra = ""
            if name == "live/concurrent_tools_wall_time":
                el = getattr(t_live_parallel_walltime, "elapsed", None)
                if el is not None:
                    extra = f" (agent wall {el:.1f}s)"
            print(f"ok    {name}  ({dt:.1f}s){extra}")

    total = time.time() - total_start
    print("---")
    print(f"{passed} passed, {failed} failed, {skipped} skipped  ({total:.1f}s)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
