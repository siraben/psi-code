#!/usr/bin/env python3
"""psi microbenchmarks.

Runs a set of fixed workloads against the psi binary and prints
timings. Used to compare before/after numbers for hot-path changes.

Each bench is a Lua expression evaluated by `psi --eval`; the script
itself just shells out and parses the printed "ms: N" line. Works
against local builds and remote hosts (`--ssh-jump/--ssh-host/--ssh-port`).

Usage:
    tests/bench.py                          # local build/psi
    tests/bench.py --psi /path/to/psi
    tests/bench.py --filter markdown
    tests/bench.py --remote                 # hippocampus over the
                                            # ProxyJump we already use
                                            # for the autosave demo
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL_PSI = str(ROOT / "build" / "psi")
TARGETS_PATH = Path(__file__).resolve().parent / "bench.targets.json"
TARGETS_EXAMPLE = Path(__file__).resolve().parent / "bench.targets.example.json"


def load_targets(path: Path) -> dict:
    """Read the bench target config. Returns {} when missing so the
    script stays usable for local-only runs without any setup."""
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as err:
        print(f"bench.py: invalid JSON in {path}: {err}", file=sys.stderr)
        return {}
    return {k: v for k, v in data.items() if not k.startswith("_")}


def target_ssh_argv(target: dict) -> tuple[list[str], list[str]]:
    """Translate a target dict into (ssh_prefix, remote_psi_argv).

    ssh_prefix is everything up to (but not including) the remote
    command to execute; remote_psi_argv is the psi invocation the
    caller wants to run on the far side. We keep them separate so
    run_bench can append `--eval <lua>` into the remote command
    before re-joining with shell quoting.
    """
    ssh = ["ssh", "-o", "BatchMode=yes"]
    if target.get("jump"):
        ssh += ["-J", target["jump"]]
    if target.get("port"):
        ssh += ["-p", str(target["port"])]
    user_host = f"{target['user']}@{target['host']}" if target.get("user") else target["host"]
    ssh += [user_host]
    return ssh, [target.get("psi", "psi")]


# ---------------------------------------------------------------------------
# Bench definitions. Each entry is (name, lua-expression).
# The expression must print a single "ms: N" line (the last line of stdout).
# ---------------------------------------------------------------------------

BENCHES: list[tuple[str, str]] = [
    (
        "markdown_render_line",
        r"""
        local md = require('psi.markdown')
        local lines = {
          '# Heading one two three',
          'This is some **bold text** and *italic* too with `code` spans.',
          '- bullet one with **inline**',
          '- bullet two with [a link](https://example.com)',
          'Regular paragraph continuing onto multiple lines to exercise wrap.',
          '```python',
          'def greet(name):',
          '    return f"hi, {name}"',
          '```',
        }
        local N = 20000
        local total = 0
        local start = os.clock()
        for _ = 1, N do
          for _, line in ipairs(lines) do
            local r = md.render_line(line, false)
            total = total + #r
          end
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  ops: %d  bytes: %d\n',
                               dt, N * #lines, total))
        """,
    ),
    (
        "session_save_growing",
        r"""
        local s = require('psi.session')
        local path = '/tmp/psi-bench-session.jsonl'
        os.remove(path)
        psi.session_set_path(path)
        -- Append 100 messages with substantial text so we exercise the
        -- per-entry JSON encode path realistically.
        for i = 1, 100 do
          s.append_user(string.rep('m', 200) .. ' ' .. i)
        end
        local N = 20
        local start = os.clock()
        for _ = 1, N do s.save() end
        local dt = (os.clock() - start) * 1000
        local size = #(psi.read_file(path) or '')
        os.remove(path)
        io.write(string.format('ms: %.1f  flushes: %d  bytes_per_save: %d\n',
                               dt, N, size))
        """,
    ),
    (
        "session_turn_shape",
        r"""
        -- Realistic turn shape: start with an existing session on
        -- disk (100 entries), then do a "turn" — append 8 new
        -- entries with 4 flushes spread across them (roughly
        -- simulating a 3-tool turn: after provider response, after
        -- each tool result, at turn end).
        local s = require('psi.session')
        local path = '/tmp/psi-bench-turn.jsonl'
        os.remove(path)
        psi.session_set_path(path)
        for i = 1, 100 do
          s.append_user(string.rep('m', 200) .. ' ' .. i)
        end
        s.save()  -- seed file
        local TURNS = 5
        local start = os.clock()
        for t = 1, TURNS do
          -- 8 appends, 4 flushes
          s.append_user('prompt ' .. t)
          s.append_assistant('response ' .. t)
          s.save()
          s.append_assistant('tool-use block ' .. t)
          s.save()
          s.append_tool_result('id' .. t, 'bash', 'some output', false)
          s.save()
          s.append_assistant('final text ' .. t)
          s.save()
        end
        local dt = (os.clock() - start) * 1000
        local size = #(psi.read_file(path) or '')
        os.remove(path)
        io.write(string.format('ms: %.1f  turns: %d  final_bytes: %d\n',
                               dt, TURNS, size))
        """,
    ),
    (
        "session_append_delta",
        r"""
        local s = require('psi.session')
        local path = '/tmp/psi-bench-delta.jsonl'
        os.remove(path)
        psi.session_set_path(path)
        for i = 1, 1000 do
          s.append_user(string.rep('m', 120) .. ' ' .. i)
        end
        s.save()
        local N = 40
        local start = os.clock()
        for i = 1, N do
          s.append_user('delta ' .. i)
          s.save()
        end
        local dt = (os.clock() - start) * 1000
        os.remove(path)
        io.write(string.format('ms: %.1f  deltas: %d  messages: %d\n',
                               dt, N, psi.session_message_count()))
        """,
    ),
    (
        "context_range_queries",
        r"""
        local s = require('psi.session')
        local c = require('psi.context')
        for i = 1, 1000 do
          s.append_user(string.rep('range-query-message-', 8) .. i)
        end
        local N = 100
        local total = 0
        local start = os.clock()
        for _ = 1, N do
          total = total + c.estimate_context_tokens().tokens
          total = total + c.keep_recent_messages(20000)
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.3f  queries: %d  checksum: %d\n',
                               dt, N * 2, total))
        """,
    ),
    (
        "read_file_slice_large",
        r"""
        local path = '/tmp/psi-bench-read-large.txt'
        local f = assert(io.open(path, 'w'))
        for i = 1, 50000 do f:write('line ', i, ' abcdefghijklmnopqrstuvwxyz\n') end
        f:close()
        local N = 80
        local bytes = 0
        local start = os.clock()
        for i = 1, N do
          local slice = psi.read_file_slice(path, 25000, 200)
          bytes = bytes + #(slice and slice.text or '')
        end
        local dt = (os.clock() - start) * 1000
        os.remove(path)
        io.write(string.format('ms: %.1f  reads: %d  bytes: %d\n', dt, N, bytes))
        """,
    ),
    (
        "ls_typed_many_entries",
        r"""
        local dir = '/tmp/psi-bench-ls'
        os.execute('rm -rf ' .. dir .. ' && mkdir -p ' .. dir)
        for i = 1, 600 do psi.file_write(dir .. '/f' .. i, 'x') end
        for i = 1, 60 do psi.mkdir_p(dir .. '/d' .. i) end
        local ls = require('psi.tools.ls')
        ls()
        local registry = require('psi.tool_registry')
        local N = 30
        local total = 0
        local start = os.clock()
        for _ = 1, N do
          local r = registry.dispatch('ls', { path = dir, limit = 1000 })
          total = total + #(r.extras and r.extras.output or '')
        end
        local dt = (os.clock() - start) * 1000
        os.execute('rm -rf ' .. dir)
        io.write(string.format('ms: %.1f  lists: %d  bytes: %d\n', dt, N, total))
        """,
    ),
    (
        "sse_feed_fragmented",
        r"""
        -- Realistic adversarial workload: several large SSE events,
        -- each fragmented into tiny TCP chunks. Exercises the
        -- stateful sse parser (no cross-chunk leftover concat).
        local anthro = require('psi.anthropic')
        local new_sse_parser = anthro._test.new_sse_parser
        local sse_push = anthro._test.sse_push
        local CHUNKS_PER_EVENT = 200
        local EVENTS = 50
        local piece = 'abcdefghijklmnop'  -- 16 bytes
        local body_chunks = {}
        for _ = 1, EVENTS do
          local ev = 'event: delta\ndata: {"text":"'
          for _ = 1, CHUNKS_PER_EVENT do ev = ev .. piece end
          ev = ev .. '"}\n\n'
          local s = 1
          while s <= #ev do
            body_chunks[#body_chunks + 1] = ev:sub(s, s + 15)
            s = s + 16
          end
        end
        local N = 10
        local events_seen = 0
        local start = os.clock()
        for _ = 1, N do
          local parser = new_sse_parser()
          for _, chunk in ipairs(body_chunks) do
            sse_push(parser, chunk, function() events_seen = events_seen + 1 end)
          end
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  iterations: %d  chunks: %d  events: %d\n',
                               dt, N, #body_chunks, events_seen))
        """,
    ),
    (
        "anthropic_text_delta_accum",
        r"""
        local t = require('psi.anthropic')._test
        local N = 200
        local CHUNKS = 2000
        local start = os.clock()
        local bytes = 0
        for _ = 1, N do
          local state = t.new_state()
          t.dispatch_sse(state, 'content_block_start', {
            index = 0,
            content_block = { type = 'text', text = '' },
          }, {})
          for i = 1, CHUNKS do
            t.dispatch_sse(state, 'content_block_delta', {
              index = 0,
              delta = { type = 'text_delta', text = 'abcd' },
            }, {})
          end
          bytes = bytes + #t.state_assistant_text(state)
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  streams: %d  chunks: %d  bytes: %d\n',
                               dt, N, CHUNKS, bytes))
        """,
    ),
    (
        "gc_pressure_tables",
        r"""
        -- Allocation-heavy workload: build a throwaway table of 50
        -- nested tables per iteration, 5000 iterations. Exercises the
        -- short-lived-allocation lifecycle the GC has to handle
        -- during streaming (each SSE chunk parse, each markdown line
        -- render, each turn builds and discards thousands of small
        -- tables). Shows the mode switch (generational vs incremental)
        -- clearly.
        local N = 5000
        local K = 50
        local acc = 0
        local start = os.clock()
        for _ = 1, N do
          local t = {}
          for i = 1, K do
            t[i] = { i, tostring(i), { i * 2, "x" } }
          end
          acc = acc + #t
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  iterations: %d  per_iter_allocs: %d  acc: %d\n',
                               dt, N, K * 4, acc))
        """,
    ),
    (
        "gc_pressure_strings",
        r"""
        -- String-heavy: many small concats + gsub passes. Simulates
        -- the markdown render path shape (before memoisation kicked
        -- in for the identical-line case). With generational GC short-
        -- string churn is cheap; with incremental the pause/stepmul
        -- tuning matters more.
        local N = 5000
        local base = 'Here is some **text** with `code` and *italics*.'
        local start = os.clock()
        for _ = 1, N do
          local s = base .. ' ' .. tostring(math.random(1000))
          s = s:gsub('%*%*(.-)%*%*', '<b>%1</b>')
          s = s:gsub('`(.-)`', '<c>%1</c>')
          s = s:gsub('%*(.-)%*', '<i>%1</i>')
          _ = #s
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  iterations: %d\n', dt, N))
        """,
    ),
    (
        "run_all_resume_cost",
        r"""
        -- Dry-run cost of sched.run_all driving K no-op coroutines.
        -- Measures table.pack / resume bookkeeping, not real I/O.
        local sched = require('psi.sched')
        local K = 8
        local N = 2000
        local start = os.clock()
        for _ = 1, N do
          local tasks = {}
          for i = 1, K do
            tasks[i] = function() return i * i end
          end
          sched.run_all(tasks)
        end
        local dt = (os.clock() - start) * 1000
        io.write(string.format('ms: %.1f  batches: %d  tasks_per_batch: %d\n',
                               dt, N, K))
        """,
    ),
]


# ---------------------------------------------------------------------------
# Runner.
# ---------------------------------------------------------------------------


def run_bench(psi_cmd: list[str], name: str, lua: str, ssh_prefix: list[str] | None, timeout: float = 60) -> str:
    """Invoke `psi --eval <lua>` and return the final 'ms: …' line.

    Local: passes lua as a list arg (no shell in the middle).
    Remote: builds a single shell-escaped command string via
    shlex.quote so ssh's sh(-c) on the far side re-parses it safely.
    """
    if ssh_prefix is not None:
        cmdline = " ".join(shlex.quote(a) for a in psi_cmd + ["--eval", lua])
        res = subprocess.run(
            ssh_prefix + [cmdline],
            capture_output=True, text=True, timeout=timeout,
        )
    else:
        res = subprocess.run(
            psi_cmd + ["--eval", lua],
            capture_output=True, text=True, timeout=timeout,
        )
    if res.returncode != 0:
        return f"FAIL: exit {res.returncode}\n{res.stderr[:400]}"
    lines = [l for l in res.stdout.strip().splitlines() if l.startswith("ms:")]
    if not lines:
        return f"FAIL: no ms: line\n{res.stdout[:400]}"
    return lines[-1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--psi", default=LOCAL_PSI, help="path to psi binary (local)")
    ap.add_argument("--filter", default=None, help="only run benches matching substring")
    ap.add_argument("--repeats", type=int, default=3,
                    help="runs per bench (print best time)")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds allowed for each individual bench run")
    ap.add_argument("--remote", nargs="?", const="", default=None,
                    help="run on a remote target from tests/bench.targets.json "
                         "(pass a name or leave blank for the first defined)")
    ap.add_argument("--targets", default=str(TARGETS_PATH),
                    help=f"alternate path to the targets config (default: {TARGETS_PATH})")
    args = ap.parse_args()

    ssh_prefix = None
    if args.remote is not None:
        targets = load_targets(Path(args.targets))
        if not targets:
            print(f"bench.py: no targets loaded from {args.targets}", file=sys.stderr)
            print(f"  cp {TARGETS_EXAMPLE} {args.targets} and edit it", file=sys.stderr)
            return 1
        name = args.remote or next(iter(targets))
        if name not in targets:
            print(f"bench.py: target '{name}' not in {args.targets}", file=sys.stderr)
            print(f"  available: {', '.join(targets.keys())}", file=sys.stderr)
            return 1
        ssh_prefix, psi_cmd = target_ssh_argv(targets[name])
        label = f"remote ({name})"
    else:
        if not Path(args.psi).exists():
            print(f"psi not found: {args.psi}", file=sys.stderr)
            return 1
        psi_cmd = [args.psi]
        label = f"local ({args.psi})"

    print(f"# psi bench — {label}")
    print()

    for name, lua in BENCHES:
        if args.filter and args.filter not in name:
            continue
        best = None
        best_line = None
        for _ in range(args.repeats):
            line = run_bench(psi_cmd, name, lua, ssh_prefix, timeout=args.timeout)
            # parse ms value
            if line.startswith("ms:"):
                try:
                    ms = float(line.split()[1])
                    if best is None or ms < best:
                        best = ms
                        best_line = line
                except (IndexError, ValueError):
                    pass
            else:
                print(f"{name:28s}  {line}")
                break
        if best_line:
            print(f"{name:28s}  {best_line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
