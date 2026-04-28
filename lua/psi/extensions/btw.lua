-- Packaged /btw extension.
--
-- /btw asks an ephemeral side question against the current transcript
-- excerpt. The answer is printed in the UI but not appended to the
-- persisted session, so it does not become future model context.

return function(psi)
  psi.commands.register("btw", {
    description = "Ask an ephemeral side question without saving it",
    argument_hint = "<question>",
    handler = function(rest)
      rest = psi.prelude.trim(rest or "")
      if rest == "" then
        return psi.records.new_command_action("print", "usage: /btw <question>")
      end
      return psi.records.new_command_action("btw", rest)
    end,
  })
end
