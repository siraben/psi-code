"""Declarative Lua test runner for the psi smoke suite.

Each ``.lua`` file under ``tests/lua/`` is one test case. A TOML metadata
block at the top of the file describes the assertion shape, fixture
files, and environment overrides. The remainder of the file is the Lua
expression handed to ``psi --eval``.

Format::

    --[[psi-test
    name = "eval/arithmetic"
    expect = "6"
    ]]
    return 1 + 2 + 3

Available metadata keys are documented in ``tests/lua/README.md``.
"""

from __future__ import annotations

import json
import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parent.parent


def smoke_env(tmp: Path) -> dict[str, str]:
    """Build the per-test environment psi runs under.

    Mirrors the helper in ``smoke.py`` so the declarative runner and the
    legacy custom-decorator runner produce identical environments.
    """
    home = tmp / "home"
    config = tmp / "config"
    state = tmp / "state"
    cache = tmp / "cache"
    for path in (home, config, state, cache):
        path.mkdir(parents=True, exist_ok=True)

    env: dict[str, str] = {}
    for key in (
        "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "TZ", "TERM", "TMPDIR",
        "SSL_CERT_FILE", "NIX_SSL_CERT_FILE", "SSH_AUTH_SOCK",
    ):
        value = os.environ.get(key)
        if value:
            env[key] = value

    for key in ("ANTHROPIC_API_KEY", "PSI_ANTHROPIC_MODEL"):
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

LUA_DIR_NAME = "lua"
# Use a level-2 long-bracket comment ``--[==[psi-test ... ]==]`` so the
# embedded TOML can contain literal ``[[arr]]`` tables without prematurely
# closing the comment under real-Lua semantics (which level-0 ``--[[ ]]``
# would). chroma's Lua lexer follows the same rule, so the level-2 form
# also keeps Forgejo / GitHub syntax highlighting correct.
META_OPEN = "--[==[psi-test"
META_CLOSE = "]==]"


@dataclass
class FileSpec:
    path: str
    text: str | None = None
    json_value: Any | None = None
    mkdir: bool = False

    def render(self, base: Path, mapping: dict[str, str]) -> None:
        target = _resolve_path(self.path, base, mapping)
        if self.mkdir:
            target.mkdir(parents=True, exist_ok=True)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        if self.json_value is not None:
            target.write_text(_render(json.dumps(self.json_value), mapping))
        else:
            target.write_text(_render(self.text or "", mapping))


@dataclass
class SplitCheck:
    sep: str
    checks: list[dict[str, Any]]


@dataclass
class LuaCase:
    file: Path
    name: str
    body: str
    expect: str | None = None
    contains: list[str] = field(default_factory=list)
    not_contains: list[str] = field(default_factory=list)
    regex: str | None = None
    cwd: str | None = None
    env: dict[str, str] = field(default_factory=dict)
    files: list[FileSpec] = field(default_factory=list)
    split: SplitCheck | None = None


def discover(root: Path) -> list[LuaCase]:
    """Find every ``.lua`` file under ``root/lua`` and parse it."""
    base = root / LUA_DIR_NAME
    if not base.exists():
        return []
    cases: list[LuaCase] = []
    for path in sorted(base.rglob("*.lua")):
        cases.append(parse_file(path, base))
    cases.sort(key=lambda c: c.name)
    return cases


def parse_file(path: Path, base: Path) -> LuaCase:
    text = path.read_text()
    meta_text, body = _split_meta(text)
    meta = tomllib.loads(meta_text) if meta_text else {}

    default_name = path.relative_to(base).with_suffix("").as_posix()
    name = meta.get("name", default_name)

    contains = _as_list(meta.get("contains"))
    not_contains = _as_list(meta.get("not_contains"))

    files = []
    for spec in meta.get("files", []):
        files.append(FileSpec(
            path=spec["path"],
            text=spec.get("text"),
            json_value=spec.get("json"),
            mkdir=bool(spec.get("mkdir")),
        ))

    split = None
    if "split" in meta:
        s = meta["split"]
        split = SplitCheck(sep=s.get("sep", "|"), checks=s.get("checks", []))

    return LuaCase(
        file=path,
        name=name,
        body=body,
        expect=meta.get("expect"),
        contains=contains,
        not_contains=not_contains,
        regex=meta.get("regex"),
        cwd=meta.get("cwd"),
        env={k: str(v) for k, v in meta.get("env", {}).items()},
        files=files,
        split=split,
    )


def prepare(case: LuaCase, tmp: Path, repo_root: Path) -> tuple[Path, dict[str, str], str]:
    """Materialise fixtures, render placeholders, and return (cwd, env, lua_body).

    The returned ``lua_body`` has a small prelude that exposes ``TMP`` and
    ``ROOT`` as locals so test files can use them without templating.
    """
    mapping = {"TMP": str(tmp), "ROOT": str(repo_root)}
    if case.cwd:
        cwd_path = (tmp / case.cwd).resolve()
        cwd_path.mkdir(parents=True, exist_ok=True)
    else:
        cwd_path = repo_root
    mapping["cwd"] = str(cwd_path)

    base = cwd_path if case.cwd else tmp
    for spec in case.files:
        spec.render(base, mapping)

    env = {k: _render(v, mapping) for k, v in case.env.items()}

    prelude = (
        f"local TMP = {json.dumps(str(tmp))}\n"
        f"local ROOT = {json.dumps(str(repo_root))}\n"
    )
    return cwd_path, env, prelude + case.body


def assert_output(case: LuaCase, output: str) -> None:
    """Apply every configured assertion. Raises AssertionError on failure."""
    stripped = output.strip()
    if case.expect is not None and stripped != case.expect:
        raise AssertionError(
            f"[{case.name}] expected {case.expect!r}, got {stripped!r}"
        )
    for needle in case.contains:
        if needle not in output:
            raise AssertionError(
                f"[{case.name}] missing {needle!r}\n--- got ---\n{output}"
            )
    for needle in case.not_contains:
        if needle in output:
            raise AssertionError(
                f"[{case.name}] unexpectedly contains {needle!r}\n--- got ---\n{output}"
            )
    if case.regex is not None and not re.search(case.regex, output, re.MULTILINE):
        raise AssertionError(
            f"[{case.name}] does not match /{case.regex}/\n--- got ---\n{output}"
        )
    if case.split is not None:
        parts = stripped.split(case.split.sep)
        for check in case.split.checks:
            idx = check["index"]
            if idx >= len(parts):
                raise AssertionError(
                    f"[{case.name}] split index {idx} out of range "
                    f"(have {len(parts)} parts: {parts!r})"
                )
            part = parts[idx]
            if "equals" in check and part != check["equals"]:
                raise AssertionError(
                    f"[{case.name}] split[{idx}] expected {check['equals']!r}, "
                    f"got {part!r}"
                )
            if "contains" in check and check["contains"] not in part:
                raise AssertionError(
                    f"[{case.name}] split[{idx}] missing {check['contains']!r} "
                    f"in {part!r}"
                )
            if "regex" in check and not re.search(check["regex"], part):
                raise AssertionError(
                    f"[{case.name}] split[{idx}] does not match "
                    f"/{check['regex']}/ in {part!r}"
                )


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _split_meta(text: str) -> tuple[str, str]:
    if not text.startswith(META_OPEN):
        return "", text
    end = text.find(META_CLOSE, len(META_OPEN))
    if end < 0:
        raise ValueError(f"unterminated {META_OPEN} block")
    meta = text[len(META_OPEN):end]
    body = text[end + len(META_CLOSE):]
    return meta.strip("\n"), body.lstrip("\n")


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return list(value)


def _render(value: str, mapping: dict[str, str]) -> str:
    out = value
    for key, replacement in mapping.items():
        out = out.replace("{" + key + "}", replacement)
    return out


def _resolve_path(p: str, base: Path, mapping: dict[str, str]) -> Path:
    rendered = _render(p, mapping)
    candidate = Path(rendered)
    if candidate.is_absolute():
        return candidate
    return base / candidate
