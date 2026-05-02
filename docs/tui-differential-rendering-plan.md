# TUI differential rendering plan

This is an audit and migration plan for moving `psi --tui` toward the
component and differential-rendering model used by `pi-mono`, while preserving
psi's C/Lua ownership split.

## Goal

Make the TUI render through composable Lua components and a line-diff renderer
instead of rebuilding a full absolute-positioned frame on every redraw.

The target behavior is:

- Lua owns components, layout, focus, rendered line caches, dirty state, and
  render scheduling.
- C owns only terminal facts and byte writes: raw mode, key normalization,
  terminal size, synchronized output writes, cursor visibility/placement, and
  suspend/restore.
- The renderer writes only changed visible lines when dimensions and viewport
  state allow it.
- Full redraw remains the fallback for first paint, width changes, shrink
  clearing, viewport ambiguity, and capability loss.
- Input, transcript, status, footer, loaders, and future overlays are separate
  components with stable render contracts.

## pi-mono reference model

The relevant `pi-mono` implementation is under
`~/pi-mono/packages/tui/src`.

Important pieces:

- `tui.ts` defines a small `Component` contract:
  `render(width) -> string[]`, `handleInput`, `wantsKeyRelease`, and
  `invalidate`.
- `Container` renders child components in order.
- `TUI` stores `previousLines`, previous terminal dimensions, focused
  component, overlay stack, render throttling, viewport state, and hardware
  cursor state.
- Rendering compares the new line array with `previousLines`, finds the first
  and last changed lines, then emits one synchronized output buffer for just
  the changed visible range.
- Full redraw is used for first render, width changes, most height changes,
  shrink clearing, and cases where the first changed line is above the prior
  viewport.
- Components render cursor position by inserting a zero-width cursor marker;
  the TUI extracts it and positions or hides the hardware cursor separately.
- Components such as `Text`, `Box`, `Loader`, `Markdown`, `Editor`, and
  `SelectList` own local caches and invalidate them when input/theme changes.
- Overlays render into their own line arrays and are composited over base
  content before diffing.

The portable idea to copy is not the TypeScript class structure. The useful
contract is "components render width-bounded line arrays, and the root renderer
diffs those arrays against the previous render."

## Current psi state

Current psi TUI files:

- `lua/psi/tui_runtime.lua`: monolithic state machine, input editor,
  transcript projection, layout, style helpers, and full-frame renderer.
- `lua/psi/tui.lua`: key policy, status helpers, busy labels, extension hooks,
  theme registry, and clipboard/status hook slots.
- `lua/psi/tui_layout.lua`: shared prompt geometry and prompt prefix policy.
- `lua/psi/markdown.lua`: line-oriented markdown styling.
- `src/lua/vm.c`: terminal primitives exposed to Lua.

The current branch has started this migration: `tui_runtime.lua` builds a
logical line frame from small components, and `tui_renderer.lua` owns
normalization, cursor marker extraction, full redraw fallback, and dirty-row
diffing. The remaining cost is that much of the runtime still builds component
inputs inline, so future overlays/focus/caches would still add pressure to the
orchestrator if not extracted carefully.

- Every redraw rewrites the header, transcript viewport, status, input box,
  and footer even when only the busy dots changed.
- Rendering and state mutation are tightly interleaved in one large module.
- Input rendering is a bespoke function rather than a component with its own
  cache/focus contract.
- Future modals, pickers, theme previews, session trees, and overlays would add
  more special cases to the monolith.
- The branch now reduces cursor jumping by letting Lua draw the prompt cursor,
  while a marker path can position the hardware cursor when explicitly enabled.
- The renderer can reason about changed logical rows, but component-level
  invalidation and focus are still future work.

## Design constraints for psi

The migration should respect existing psi architecture:

- Keep component and diff policy in Lua.
- Keep C changes minimal and terminal-specific.
- Preserve build gates: `TUI=0` and `ANSI=0` must still compile and fail
  cleanly for `--tui`.
- Continue routing styles through `psi.ansi` and theme helpers.
- Keep provider/session/tool semantics outside the component system.
- Keep the TUI cooperative with `psi.sched` and `psi.host_tick()`.
- Avoid introducing a second event loop or background Lua owner.

## Proposed Lua module split

Add focused modules instead of expanding `tui_runtime.lua`:

- `lua/psi/tui_component.lua`
  - component constructors and common helpers
  - `component.render(width) -> lines`
  - `component.invalidate()`
  - optional `component.handle_key(event, context)`
  - optional `component.focused`

- `lua/psi/tui_renderer.lua`
  - previous-line cache
  - viewport tracking
  - first/last changed line detection
  - full-redraw fallback rules
  - synchronized output buffer construction
  - cursor marker extraction
  - debug counters and render traces

- `lua/psi/tui_components/*.lua`
  - `text`
  - `box`
  - `loader`
  - `markdown`
  - `transcript`
  - `input_editor`
  - `status_bar`
  - `footer_bar`
  - later: `select_list`, `settings_list`, `session_tree`, `overlay`

Keep `tui_runtime.lua` as the orchestrator during migration. It should own the
agent turn, session mutation, key routing, and busy state, but delegate screen
projection to components and `tui_renderer`.

## Render contract

Every component should return an array of terminal lines with these rules:

- Lines are already styled with ANSI when ANSI/color are enabled.
- Visible width must be `<= width`, except for explicitly supported image
  protocols if psi later ports them.
- Components may cache by `(content, width, theme generation)`.
- Components must expose `invalidate()` for theme reload and force redraw.
- Components should not include absolute cursor movement.
- Components that want hardware cursor placement insert a zero-width marker.

Suggested marker:

```lua
local CURSOR_MARKER = "\27_psi:c\7"
```

The root renderer strips markers before diffing/writing and then calls the
existing cursor primitive only if hardware cursor placement is enabled.
For the current TUI, hardware cursor can remain hidden by default.

## Differential renderer plan

The base implementation should make the render target explicit without
committing to a future cell-buffer model:

- `tui_runtime.lua` renders a complete logical frame:
  `{ width, height, lines, cursor, force_full }`.
- `tui_renderer.new()` returns a stateful renderer object.
- `renderer:render(frame)` normalizes rows, strips cursor markers, appends line
  resets, compares with the previous frame, and chooses full, diff, or skip.
- The default Lua backend emits full frames through `psi.tui_render_frame` and
  differential frames through `psi.stdout_write`.
- Full redraw remains mandatory for first render, dimension changes, explicit
  clear, and missing raw-writer support.
- Stable-size redraws emit contiguous dirty row ranges, not one broad changed
  span, so disjoint updates do not rewrite unchanged rows in between.

This keeps today's implementation line-oriented and small while leaving room
for a future cell-buffer backend behind the same frame boundary.

### Future: focus and overlay foundation

- Add root focus management for components.
- Keep input editor as the default focus target.
- Add an overlay stack with layout options: width, max height, anchor, margin,
  non-capturing, hidden.
- Composite overlays into the line buffer before diffing.
- Use this for future `/theme`, `/model`, `/session`, and `/tree` pickers.

This should be a foundation only. Do not port every pi-mono overlay at once.

### Future: component-owned caches and invalidation

- Add cache keys to text/markdown/transcript/input components.
- Add a theme generation counter. Theme reload invalidates the component tree.
- Add debug counters for full redraws, diff renders, changed-line spans, and
  cache hits.
- Add tests around width changes, shrink clearing, overlay composition, and
  cursor marker extraction.

## C boundary changes

No broad C UI rewrite is needed.

Likely required or useful primitives:

- `psi.tui_write(text)` or reuse an existing raw stdout write if it is safe
  while TUI mode is active.
- `psi.tui_render_frame(text, row, col, visible)` can remain as the full-redraw
  fallback during migration.
- Cursor placement should remain terminal-only: C moves/hides/shows; Lua
  decides when.

Avoid moving diff logic into C. The line diff and component model need access
to Lua-rendered text, theme state, and component caches.

## Testing plan

Add pure Lua tests first, then terminal-byte regression tests.

Pure Lua:

- component render output respects visible width
- component cache invalidates on text, width, and theme generation changes
- root render produces stable line arrays for representative states
- cursor marker extraction reports row/column and strips marker
- overlay composition clips and pads correctly
- differential planner returns full-redraw reasons for width/height/viewport
  cases
- busy loader changes only the status/footer line

Terminal-byte tests:

- first render emits a synchronized full output
- status-only update emits one changed row, not the full frame
- appended transcript lines scroll without clearing the prompt
- shrinking input clears stale rows
- width change falls back to full redraw
- hardware cursor is hidden by default and only positioned when explicitly
  enabled

Manual checks:

- `PSI_PROVIDER=openai-codex ./build/psi --tui`
- busy no-stream network wait: seconds, shimmer, and dots continue ticking
- long assistant output while typing
- `/btw` unavailable while busy, then typing restores busy status
- resize narrow/wide with multiline input
- Ctrl-D on empty prompt

## Risks and mitigations

- **Scrollback and viewport drift.** Keep full redraw fallback conservative
  until differential math is covered by tests.
- **ANSI width bugs.** Centralize visible-width, truncate, and slice helpers
  before diffing; do not duplicate width logic across components.
- **Theme style leaks.** Append a reset/hyperlink reset to every non-image line
  before comparison and write.
- **Cursor flicker.** Keep the hardware cursor hidden by default and use a
  marker-driven placement path only when enabled.
- **Monolith migration churn.** First introduce renderer/component seams while
  preserving the existing visual output; then turn on diffing.
- **Extension breakage.** Preserve current key/status/clipboard hooks and map
  them onto component slots later.

## Suggested PR sequence

1. Add `tui_renderer` with logical line full-render fallback and tests.
2. Extract root/header/status/footer/input/transcript line producers as
   components while still full-rendering.
3. Enable differential rendering for same-size terminal frames.
4. Add cursor marker extraction and optional hardware cursor placement.
5. Add overlay stack and a small select-list consumer.
6. Add component cache/theme invalidation counters and debug render logs.

Each PR should leave `--tui` usable and keep full redraw as an escape hatch.
