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
    for fruit in ("apple", "banana", "cherry"):
        assert_contains(text, fruit, f"{fruit} in TUI output")
    # Three distinct tool-call headers (╭─) must have rendered. ncurses
    # repaints many frames; we expect the marker to appear at least
    # three times across the session.
    panel_opens = text.count("╭─")
    assert_true(
        panel_opens >= 3,
        f"expected >=3 panel openings (╭─), got {panel_opens}",
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
