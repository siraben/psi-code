# Parity review — session PRs #212–#223 vs pi-mono

**Date:** 2026-08-22 · **Method:** dual-model parallel discovery (11 Claude subagents + 11 Codex CLI reviewers, all concurrent), full cross-validation — every finding adjudicated by the opposite model. Reference: `~/pi-mono` @ `c49906ec` (refreshed). psi CI treated as green per Forgejo Actions.

**Question answered:** does each PR bring psi to parity with pi-mono for its feature?

## Verdicts at a glance

| PR | Feature | Parity | Surviving findings |
|---|---|---|---|
| #212 | Overlay focus restoration | **ACHIEVED** | none |
| #213 | External-editor cleanup | **ACHIEVED** | none |
| #215 | Undo + kill ring | PARTIAL | 4 should_fix, 0 nits |
| #216 | Queue-abort draft restore | PARTIAL | 1 should_fix |
| #217 | Ctrl-V clipboard text paste | PARTIAL | 0 findings (documented divergences only) |
| #218 | Short-terminal viewports | PARTIAL | 2 should_fix, 1 nit |
| #219 | Atomic large-paste markers | PARTIAL | 3 should_fix, 1 nit |
| #220 | Indic conjunct graphemes | PARTIAL | 1 should_fix |
| #221 | CR-safe rendering | PARTIAL | 1 should_fix |
| #222 | Clipboard image paste | PARTIAL | ≥1 should_fix (+2 pending validation) |
| #223 | Lua fallback wrapping | PARTIAL | 1 should_fix |

Cross-validation outcome: **every finding from both models survived** (17 confirmed; one severity downgraded should_fix→nit on #219; one factual aside corrected inside #223's validated finding).

## The five findings that most affect merge order

1. **#222 Windows image paste is dead as shipped** (`clipboard_image.lua:212-221`) — `powershell.exe -Command <script> <path>` folds the path into command text, `$args[0]` is null, `Save($null,…)` always throws. Silent fallback to text paste on the advertised platform. Fix by interpolating the path into the script like pi-mono does.
2. **#219 completion acceptance wipes the paste registry while markers can survive in preserved tail text** (`tui_runtime.lua:789-802`) — later submit sends literal `[paste #N …]` instead of pasted bytes; breaks the feature's losslessness guarantee.
3. **#218 chat-mode live region taller than screen duplicates rows into scrollback every repaint** (`tui_runtime.lua:2416-2430`) — newly introduced on exactly the terminals this PR targets; needs viewport-top tracking or a bounded erase window.
4. **#216 consuming a different queued message during preview permanently drops the saved draft and can double-send on abort** (`tui_runtime.lua:3853-3866`) — defeats the PR title's own invariant on an interleaving reachable mid-turn.
5. **#215 four integration gaps**: legacy Ctrl-Minus byte undecoded (undo unreachable outside kitty CSI-u), Unicode whitespace not creating undo word boundaries, Ctrl-R recall un-snapshotted, rejected submit clears history before restoring input.

## Per-PR detail

See [PR-212](PR-212.md) · [PR-213](PR-213.md) · [PR-215](PR-215.md) · [PR-216](PR-216.md) · [PR-217](PR-217.md) · [PR-218](PR-218.md) · [PR-219](PR-219.md) · [PR-220](PR-220.md) · [PR-221](PR-221.md) · [PR-222](PR-222.md) · [PR-223](PR-223.md)

## Cross-validated residual gaps vs pi-mono (no diff defect)

- #213: pi removes the whole per-edit temp *directory* (vim sidecars die); psi unlinks one file. Extensionless editor filename (pi uses `prompt.md`).
- #217: pi binds alt+v on win32; native-library read backend absent (psi CLI probes exceed pi on Termux); 256 KiB vs 50 MiB read caps.
- #219: undo doesn't restore markers (scoped out pending #215); over-wide marker split position differs; suffix-less `[paste #N]` not recognized.
- #220: matra/spacing-mark attachment still splits where ICU joins (wcwidth table lacks Devanagari zero-width entries); non-ZWJ InCB extenders between linker+consonant split; bare-ZWJ+spacing-mark now splits (malformed orthography only).
- #221: trailing-newline empty-line semantics differ (masked by callers); tab expansion missing on non-paste insert paths.
- #222: WSL/BMP/TIFF conversion intentionally omitted; macOS via osascript rather than native module.

## Limitations

Static review; no manual TUI runs. pi-mono runtime behavior probed empirically only for #220 (Node ICU 78.3 segmentation oracle). #222 reviewed stacked on #217. All 17 surviving findings were confirmed by cross-validation; nothing was rejected outright, so no rejection log is included.
