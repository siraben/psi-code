from __future__ import annotations

from pathlib import Path

import pytest

import lua_runner

ROOT = Path(__file__).resolve().parent.parent


def pytest_addoption(parser):
    group = parser.getgroup("psi smoke")
    group.addoption("--psi", default="build/psi",
                    help="path to psi binary")
    group.addoption("--filter", default=None,
                    help="only run smoke tests whose name contains this substring")
    group.addoption("--exclude", action="append", default=[],
                    help="skip smoke tests whose name contains this substring; may be repeated")
    group.addoption("--no-live", action="store_true",
                    help="skip live-agent smoke tests even if ANTHROPIC_API_KEY is set")


def _filter_cases(config, cases):
    name_filter = config.getoption("--filter")
    excludes = config.getoption("--exclude") or []
    selected = []
    for case in cases:
        if name_filter and name_filter not in case.name:
            continue
        if any(excluded in case.name for excluded in excludes):
            continue
        selected.append(case)
    return selected


def pytest_collection_modifyitems(config, items):
    """Apply --filter/--exclude to plain pytest functions too."""
    name_filter = config.getoption("--filter")
    excludes = config.getoption("--exclude") or []
    if not name_filter and not excludes:
        return
    skipped = pytest.mark.skip(reason="filtered out by --filter/--exclude")
    for item in items:
        # Lua cases already filtered in pytest_generate_tests.
        if "lua_case" in item.fixturenames:
            continue
        ident = getattr(item, "callspec", None)
        if ident is not None:
            ident = ident.id
        ident = ident or item.name
        if name_filter and name_filter not in ident:
            item.add_marker(skipped)
            continue
        if any(excluded in ident for excluded in excludes):
            item.add_marker(skipped)


def pytest_generate_tests(metafunc):
    if "lua_case" in metafunc.fixturenames:
        cases = _filter_cases(metafunc.config, lua_runner.discover(Path(__file__).resolve().parent))
        metafunc.parametrize(
            "lua_case",
            cases,
            ids=[c.name for c in cases],
        )
