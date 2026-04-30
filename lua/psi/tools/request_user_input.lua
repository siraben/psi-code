local records = require("psi.records")
local registry = require("psi.tool_registry")
local helpers = require("psi.tool_helpers")
local sched = require("psi.sched")

local function normalize_questions(raw)
  if type(raw) ~= "table" or #raw == 0 then
    return nil, "missing questions array"
  end
  if #raw > 3 then
    return nil, "request_user_input accepts at most three questions"
  end
  local out = {}
  for i, q in ipairs(raw) do
    if type(q) ~= "table" then
      return nil, "question " .. tostring(i) .. " must be an object"
    end
    local id = type(q.id) == "string" and q.id ~= "" and q.id or ("q" .. tostring(i))
    local question = type(q.question) == "string" and q.question ~= "" and q.question or nil
    if not question then
      return nil, "question " .. tostring(i) .. " is missing question"
    end
    local options = {}
    if type(q.options) == "table" then
      for _, option in ipairs(q.options) do
        if type(option) == "table" then
          local label = option.label or option.value or option.text
          if type(label) == "string" and label ~= "" then
            options[#options + 1] = {
              label = label,
              description = type(option.description) == "string" and option.description or nil,
            }
          end
        elseif type(option) == "string" and option ~= "" then
          options[#options + 1] = { label = option }
        end
      end
    end
    out[#out + 1] = {
      header = type(q.header) == "string" and q.header or nil,
      id = id,
      question = question,
      options = options,
    }
  end
  return out, nil
end

local function impl(input)
  local questions, err = normalize_questions(input.questions)
  if not questions then
    return records.tool_failure("request_user_input", err)
  end
  local answers = sched.user_input(questions)
  return records.new_tool_result(true, "request_user_input", nil, {
    answers = answers or {},
    questions = questions,
    output = "received " .. tostring(#questions) .. " answer(s)",
  })
end

return function()
  helpers.register(registry, records, {
    name = "request_user_input",
    description = "Ask the user one to three short questions and wait for answers.",
    prompt_snippet = "Request concise user input when truly blocked",
    guidelines = {
      "Use request_user_input only when a reasonable assumption would be risky.",
    },
    input_schema = helpers.schema_object({
      questions = {
        type = "array",
        items = helpers.schema_object({
          header = helpers.schema_type("string"),
          id = helpers.schema_type("string"),
          question = helpers.schema_type("string"),
          options = {
            type = "array",
            items = helpers.schema_object({
              label = helpers.schema_type("string"),
              description = helpers.schema_type("string"),
            }, { "label" }),
          },
        }, { "id", "question" }),
      },
    }, { "questions" }),
    impl = impl,
    opts = { execution_mode = "sequential" },
  })
end
