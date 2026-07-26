---
name: psi-pr-review
description: Review psi pull requests and branch diffs against origin/master. Use when asked to review, audit, compare, or verify changes in this repository, especially PR reviews, branch diffs, ports from pi-mono, and architecture-sensitive changes.
---

# psi PR Review

Review-only workflow for `psi`. Do not edit code while using this skill unless the user separately asks to fix findings.

## Baseline

1. Start from the actual repo state.
   - `git status --short --branch`
   - `git fetch origin master` when network is available and a current base matters.
   - `BASE=$(git merge-base origin/master HEAD)`
   - Review `git diff "$BASE"...HEAD`, `git diff --cached`, and unstaged tracked changes.
   - Include untracked files from `git ls-files --others --exclude-standard`; `git diff` will not show them.
2. Read the relevant project context before judging design:
   - Always: `README.md`, `docs/architecture.md`
   - Portability or C changes: `docs/portability.md`
   - pi-mono parity or porting changes: `docs/port-status.md`
   - Extension, hook, command, tool API changes: `docs/extensions.md`
   - Provider changes: `docs/providers.md`
3. If the branch has a PR, inspect its title, body, and comments with the repository host's connector or CLI.

## Review Lens

psi is a C89 host with Lua policy. Review changes against these invariants:

- Keep the C host small. C owns OS, terminal, process, filesystem, HTTP, abort, and Lua embedding boundaries; agent policy belongs in Lua.
- Keep Lua single-threaded. Helper threads and subprocesses communicate through pollable handles and buffers; no helper thread may call into Lua.
- Keep frontends thin. `--print`, `--agent`, `--repl`, and `--tui` should share session, provider, tool, and render semantics.
- Prefer append-only durable state for sessions, tool events, compaction, and metadata.
- Gate optional host capabilities. New terminal, ANSI, color, process, filesystem, network, or library-backed behavior should compile out cleanly and be discoverable through runtime capability checks.
- Preserve portability. C must remain C89: no `bool`, `//` comments, VLAs, designated initializers, compound literals, anonymous structs, or unchecked POSIX assumptions in headers.
- Keep TUI ownership split clean. Lua owns TUI state and policy; C reports terminal facts and draws.
- Route rendering style through `lua/psi/ansi.lua` and capability gates instead of hard-coded escapes.
- Keep tools structured. Built-in tools should validate inputs, return `ToolResult` records, preserve model-visible payload shape, and serialize file mutations by path.
- Keep provider code frontend-agnostic. Providers should stream through observers, dispatch tools through the shared tool runtime, append durable session records, and avoid terminal/layout policy.
- Keep shell/process streaming shared and bounded. Long-running tools should forward live progress without repeatedly buffering or appending the same bytes, then produce one final structured result for the session log.
- Preserve hookable dispatch. Extension and internal callers should prefer `psi.tool_call` / registry dispatch paths over direct `impl` calls when before/after hooks, permissions, redaction, or result transforms should apply.
- Treat cancellation as consistency-sensitive. Aborts should stop future work, persist coherent tool/session state, and allow the next turn to start normally.

When reviewing a port or parity claim against `pi-mono`, compare with the upstream `badlogic/pi-mono` repository (`git@github.com:badlogic/pi-mono`). Match behavior where the architecture is the same; call out and justify differences where psi's C/Lua boundary or capability model makes a different design cleaner.

## Finding Standard

Flag only issues that are both introduced or worsened by the diff and independently verified.

For every candidate:

1. Read the actual file, not just the hunk.
2. Trace the code path from source to sink.
3. Search for existing helpers and sibling patterns before claiming duplication.
4. Check feature gates, host capability assumptions, and non-TUI modes.
5. Confirm whether tests, compiler flags, or smoke coverage would already catch it.

Drop a candidate if it is pre-existing, speculative, preference-only, caught trivially by CI, not tied to a concrete runtime failure, or based on a pi-mono pattern that psi intentionally does differently.

## Output Format

Lead with findings, ordered by severity. Use this structure:

```
Blocking
- `path:line` Title
  Observable fact -> consequence -> fix direction.

Should Fix
- `path:line` Title
  Observable fact -> consequence -> fix direction.

Nits
- `path:line` Title
  Only include real cleanup that matters.

Open Questions
- Concrete questions or assumptions, if any.

Residual Risk
- Test gaps or areas not inspected, if relevant.
```

If there are no issues, say so clearly and list what was checked plus any residual test risk. Keep summaries brief; do not hide findings behind a high-level overview.

## Verification Guidance

Choose verification based on the changed surface:

- Always consider `make build/psi` for Lua/C changes.
- Run targeted smoke tests with `./tests/smoke.py --filter <name>` for narrow changes.
- Run `./tests/smoke.py` before declaring broad runtime, session, provider, TUI, or tool changes clean.
- For C portability-sensitive changes, also consider `nix run .#analyze` or `tests/valgrind.sh` when the risk justifies the cost.
- For visual/TUI changes, prefer a direct TUI smoke path or focused terminal reproduction instead of relying only on pure Lua tests.

Report commands that were run and commands that were intentionally skipped.
