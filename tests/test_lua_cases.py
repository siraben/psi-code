"""Pytest entry point that runs every declarative ``.lua`` case.

The cases themselves live under ``tests/lua/<category>/<name>.lua`` with
TOML metadata at the top of each file. Discovery and assertion logic
live in ``lua_runner``; this file is the thin pytest glue.
"""

from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

import pytest

import lua_runner

ROOT = Path(__file__).resolve().parent.parent


def test_lua_case(lua_case: lua_runner.LuaCase, tmp_path: Path, request):
    binary = Path(request.config.getoption("--psi")).resolve()
    if not binary.exists():
        pytest.fail(
            f"psi binary not found at {binary}; build it or pass --psi",
            pytrace=False,
        )

    cwd, env_extra, body = lua_runner.prepare(lua_case, tmp_path, ROOT)

    env = lua_runner.smoke_env(tmp_path)
    env["PWD"] = str(cwd)
    for key, value in env_extra.items():
        if value == "":
            env.pop(key, None)
        else:
            env[key] = value

    argv = [str(binary), "--eval", body]
    result = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(cwd),
        timeout=60,
    )
    if result.returncode != 0:
        pytest.fail(
            f"[{lua_case.name}] {shlex.join(argv[:2])} exited {result.returncode}\n"
            f"--- file ---\n{lua_case.file}\n"
            f"--- stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}",
            pytrace=False,
        )

    try:
        lua_runner.assert_output(lua_case, result.stdout)
    except AssertionError as exc:
        pytest.fail(str(exc), pytrace=False)
