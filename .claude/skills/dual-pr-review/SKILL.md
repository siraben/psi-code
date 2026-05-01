---
name: dual-pr-review
description: Dual-model (Claude + Codex) review of a PR or branch diff against `origin/master`, layered on top of psi's review lens. Staged: bundle → summary → parallel discovery → cross-model validation → consolidated report. Triggers on "dual review", "review PR", or "/dual-pr-review <PR#|branch>".
---

# Dual PR Review

Two reviewers (Claude opus + Codex) walk the diff in parallel, cross-validate each other's findings, and the surviving claims go into a single report. Built on top of psi's invariants. Review-only — no code changes.

## Phase 0: Build review bundle

### A. Compute the diff
```bash
BASE=$(git merge-base origin/master HEAD)
git diff "$BASE"...HEAD                            # committed changes
git diff --cached                                  # staged
git ls-files --others --exclude-standard           # untracked (read manually)
git log --no-merges --format='- %h %s' "$BASE..HEAD"
```

For a PR review against another worktree, use the PR head explicitly:
```bash
git diff origin/master...<pr-head-sha>
```

### B. Build per-file instruction scope
- Root: `AGENTS.md`, `CLAUDE.md`, `.cursorrules` (if any)
- Scoped: any `AGENTS.md`/`CLAUDE.md` in parent directories of changed files
- Per-area docs (only when relevant):
  - C / portability changes → `docs/portability.md`, `docs/architecture.md` §1, §2
  - pi-mono parity → `docs/port-status.md`, compare against `~/pi-mono/`
  - Tool/extension API → `docs/extensions.md`
  - Provider changes → `docs/providers.md`
  - TUI changes → `docs/architecture.md` §TUI
- The existing local skill `.codex/skills/psi-pr-review/SKILL.md` is the canonical psi review lens — load its full contents and pass to every reviewer agent.

### C. PR context
If a Forgejo PR exists: pull title + body + open comments via the API:
```bash
curl -s -H "Authorization: token $TOKEN" \
  "http://127.0.0.1:3010/api/v1/repos/siraben/psi-coding-agent/pulls/<N>" | jq '...'
```

### D. Determine review mode
**Critical** when the diff touches: HTTP/network code (`src/core/http_*.c`, providers), session persistence (`src/core/session.c`, `lua/psi/session_manager.lua`), auth/credentials (`auth_storage.lua`, `oauth_*`), abort/cancellation, the C-Lua boundary (`src/lua/vm.c`, `src/core/process.c`), or feature-gate scaffolding. Otherwise **Standard**.

### E. Early exit
Empty diff with no untracked files → "nothing to review" and stop.

## Phase 1: Summary and intent

A single pass (Claude or Codex, whichever responds first) establishes:
- **Author intent** (1–2 sentences) from PR body + commit messages — do NOT invent.
- **Changed areas** (2–8 short strings).
- **High-risk areas** — only the truly risky ones; prefer empty over weak.
- **Review focus** — concrete checks to emphasize.

This summary anchors every Phase 2 agent.

## Phase 2: Parallel discovery — Claude + Codex

Launch ALL of these in parallel. Each receives: full diff, applicable instructions, doc summaries, the psi review lens (from `.codex/skills/psi-pr-review/SKILL.md`), and Phase 1 summary.

### Structured output

Every reviewer returns findings in this shape:

```
- title: short
- path: file
- line: number or range
- severity: blocking | should_fix | nit
- category: instruction_violation | bug | security | api_boundary | data_integrity | performance | architecture | reviewability
- reason_flagged: one sentence
- body: observable fact → concrete consequence → fix direction
- instruction_path: <doc/instr file or null>
- instruction_quote: <exact rule text or null>
```

### Codex track (`codex exec -`)

Two prompts written to `/tmp/`, each piped to `codex exec -`. Use 600s timeout. Capture full stdout (never `head`/`tail` truncate) by redirecting to a file.

**Codex A — Architecture & instruction compliance.** Quote exact rules from `docs/architecture.md` and the local skill. Flag clear violations only. Prefer zero findings over weak findings.

**Codex B — Bugs / security / data-integrity.** Adversarial. Trust boundaries, irreversible state changes, retry/concurrency/error paths, signal-safety, partial-write corruption, command/path injection, credential exposure, libcurl/pthread races, abort propagation.

### Claude track (Agent subagents, opus)

Partition the diff into 3–6 areas based on file groups; one subagent per area. Each receives the bundle, the area assignment, and is told to ignore everything outside it. Plus one **cross-cutting reviewer** that looks for module-boundary violations and contract drift between layers.

### Anti-hallucination gates (every finding must survive)
1. Read the actual file, not just the hunk.
2. Trace data source → sink for logic claims.
3. Search for existing helpers / sibling patterns before claiming duplication.
4. No "likely"/"probably"/"appears to" — verify or drop.
5. If uncertain, drop.

### Drop rules
- Pre-existing and not made worse by this diff.
- Preference-only without a hard invariant violation.
- CI/compiler/linter would catch it trivially.
- Speculative without a verifiable failure path.
- Cannot be tied to an exact rule quote OR a concrete runtime failure.
- Documented as out-of-scope in `docs/port-status.md` (RPC, session-tree, sandboxing, branch-aware compaction).

### Wait for all agents

Do NOT start Phase 3 until every Phase 2 agent has finished or been recorded as failed/timed-out. Failure mode goes into the final report.

## Phase 3: Cross-validate — opposite model verifies each finding

### Codex findings → validated by Claude
For each Codex finding, a Claude opus agent reads the actual code path, applies the gates and drop rules, and returns binary VALID|REJECTED + reasoning.

### Claude findings → validated by Codex
Collect Claude findings into one prompt at `/tmp/codex-validate.md`, pipe to `codex exec -`. Codex returns VALID|REJECTED per finding.

A finding survives ONLY if the cross-validator confirms it. Rejected findings move to the chain-of-thought section, NOT the final report.

## Phase 4: Report

The final artifact is a single markdown document. Sections in order:

1. **Header** — PR number/title, base/head, total commits, files changed, mode (Standard/Critical), models used, date.
2. **Summary table** — every surviving finding, one line each, with severity, file:line, category, who-found, who-validated.
3. **Project intent** — 1 paragraph from Phase 1.
4. **Blocking findings** — title, `path:line`, observable fact → consequence → fix direction. Quote the exact rule for instruction violations.
5. **Should-fix findings** — same shape.
6. **Nits** — only when the PR is otherwise clean.
7. **Architecture observations** — non-blocking module-boundary / structural notes.
8. **Follow-ups** — concrete maintainability items grounded in code that was actually read.
9. **Limitations** — what wasn't reviewed (e.g. live agent paths, manual TUI), agent failures, why.
10. **Rejected during cross-validation** — every dropped candidate with a one-line reason. (Auditable so reviewers can see what was considered and why it didn't make the bar.)

Write to `reviews/PR-<N>.md` (or `reviews/branch-<slug>.md` for branch reviews). Commit to a dedicated `review/pr-<N>` branch off `origin/master` and push.

## Rules

- Do NOT make code changes. Report only.
- All subagents review-only.
- Don't ask the user questions; complete autonomously.
- Every finding grounded in code actually read.
- One finding per issue.
- Prefer zero findings over weak findings.
- Final visible artifact is the markdown report.
