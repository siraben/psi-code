--[==[psi-test
expect = "ok"
]==]
-- Regression test for the diff/margin bug: the default word-wrapping path
-- (preserve_whitespace = false) must preserve leading indentation and internal
-- whitespace runs, matching pi's wrapTextWithAnsi. Only whitespace that would
-- begin a soft-wrapped continuation line may be dropped. This is verified for
-- both the native (psi_vm_text_wrap_ansi) and the Lua fallback paths.

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected [" .. tostring(expected) .. "] got [" .. tostring(actual) .. "]", 0)
  end
end

local function run(text)
  -- Leading indentation on the first (unwrapped) source line is preserved.
  local a = text.wrap_ansi("    deeply indented", 40)
  assert_eq(#a, 1, "single line")
  assert_eq(a[1], "    deeply indented", "leading indentation preserved")

  -- Indentation preserved across hard newlines.
  local b = text.wrap_ansi("def f():\n    return 1\n  x = 2", 40)
  assert_eq(#b, 3, "three source lines")
  assert_eq(b[1], "def f():", "line 1")
  assert_eq(b[2], "    return 1", "line 2 indentation preserved")
  assert_eq(b[3], "  x = 2", "line 3 indentation preserved")

  -- Internal whitespace runs are not collapsed to a single space.
  local c = text.wrap_ansi("a    b", 40)
  assert_eq(#c, 1, "internal spaces single line")
  assert_eq(c[1], "a    b", "internal whitespace run preserved")

  -- Whitespace beginning a soft-wrapped continuation line is dropped.
  local d = text.wrap_ansi("aaa bbb ccc ddd", 7)
  assert_eq(#d, 2, "wrap to two lines")
  assert_eq(d[1], "aaa bbb", "first wrapped line")
  assert_eq(d[2], "ccc ddd", "continuation has no leading whitespace")
end

-- Native path (if compiled in).
run(require("psi.tui_text"))

-- Lua fallback path.
psi.tui_text_wrap_ansi = nil
package.loaded["psi.tui_text"] = nil
run(require("psi.tui_text"))

return "ok"
