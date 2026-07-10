-- psi.openai_compat: shared machinery for OpenAI-flavoured
-- chat/completions providers.
--
-- Both Ollama (native `POST /api/chat`) and OpenRouter (OpenAI
-- `POST /v1/chat/completions`) speak an "OpenAI-ish" wire format:
-- messages list with `role`, tool calls represented as
-- `{role:"assistant", tool_calls:[{id, function:{name, arguments}}]}`,
-- tool results as `{role:"tool", content}`. The exact shape,
-- streaming format, and a handful of quirks (fragmented arguments,
-- cached_tokens disambiguation, done signal) differ per provider —
-- but the surrounding skeleton (session → messages, run_turn loop,
-- concurrent tool dispatch, session persistence, event emission) is
-- identical.
--
-- This module owns that skeleton. Each provider (psi.ollama,
-- psi.openrouter) supplies a small bag of callbacks + metadata:
--
--   cfg.provider_name        string    "ollama" | "openrouter" | …
--   cfg.api_name             string    "ollama-chat" | "openrouter-chat-completions"
--   cfg.url                  string    full URL for streaming chat
--   cfg.headers              array     HTTP headers
--   cfg.request_body(args)   table     args = {messages, tool_specs, model,
--                                              max_tokens, abort}; returns
--                                              the body table to JSON-encode.
--   cfg.parser_new()                   returns a fresh parser state (table)
--   cfg.parser_push(parser, chunk, state, observer)
--                                      feeds one raw chunk; advances state,
--                                      fires observer callbacks.
--   cfg.finalize_tool_calls(state)     -> [{id, name, arguments_table}, …]
--   cfg.tool_result_message(tool_call_id, tool_name, text)
--                                      -> {role="tool", …} shape for
--                                      build_api_messages.
--   cfg.assistant_tool_call(block)     translates an in-session
--                                      {type="toolCall", id, name,
--                                      arguments} into the tool_calls[i]
--                                      shape this provider expects.
--   cfg.include_response_id  bool      if true, pass state.response_id to
--                                      session.append_assistant (OpenRouter).

local prelude = require("psi.prelude")
local provider_loop = require("psi.provider_loop")
local sched = require("psi.sched")
local transform = require("psi.transform_messages")
local image_policy = require("psi.image_policy")
local tools = require("psi.tools")
local session_mod = require("psi.session_manager")
local notice = require("psi.notice")

local M = {}

local function clean_text(text)
  return prelude.sanitize_surrogates(text or "")
end

local function state_text(state)
  if type(state.text) == "string" then
    return state.text
  end
  state.text = table.concat(state.text_parts or {})
  return state.text
end

local function state_thinking(state)
  if type(state.thinking) == "string" then
    return state.thinking
  end
  state.thinking = table.concat(state.thinking_parts or {})
  return state.thinking
end

local safe_decode = prelude.safe_json_decode

-- ---------- HTTP error classification ----------
--
-- When a provider returns a non-2xx status, the response body is
-- typically a JSON error envelope. Common shapes:
--   {"error": {"message": "...", "type": "..."}}   (OpenAI, Anthropic, OpenRouter)
--   {"error": "..."}                                (some Ollama builds)
-- Extract the most informative string we can and prepend an
-- HTTP-status-specific hint when it tells the user something
-- actionable. Matches pi-mono's error-body passthrough behaviour
-- so operators don't have to tail stderr to learn what went wrong.
function M.classify_http_error(status, body, provider_name)
  local detail = nil
  if type(body) == "string" and body ~= "" then
    local parsed = safe_decode(body)
    if type(parsed) == "table" then
      local err = parsed.error
      if type(err) == "table" then
        detail = err.message or err.type or err.code
      elseif type(err) == "string" then
        detail = err
      elseif type(parsed.message) == "string" then
        detail = parsed.message
      end
    end
    if not detail then
      -- No structured error — include a short trimmed snippet so
      -- the user sees SOMETHING rather than just the status code.
      local trimmed = body:gsub("%s+", " "):sub(1, 200)
      if trimmed ~= "" then
        detail = trimmed
      end
    end
  end

  local hint = nil
  if status == 401 or status == 403 then
    hint = "check your API key"
  elseif status == 429 then
    hint = "rate limited — retry after a moment or switch model"
  elseif status == 404 then
    hint = "model or endpoint not found — check the model slug"
  elseif status == 413 then
    hint = "request too large — context or output may need trimming"
  elseif status == 529 or status == 503 then
    hint = "provider is overloaded — try again shortly"
  elseif status >= 500 then
    hint = "provider-side error — retry or check status page"
  end

  local parts = { string.format("%s request failed (%d)", provider_name, status) }
  if hint then
    parts[#parts + 1] = "— " .. hint
  end
  if detail then
    parts[#parts + 1] = "— " .. detail
  end
  return table.concat(parts, " ")
end

-- ---------- Tool specs (identical across both providers) ----------

function M.api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      type = "function",
      ["function"] = {
        name = t.name,
        description = t.description,
        parameters = t.input_schema,
      },
    }
  end
  return out
end

-- ---------- Session -> OpenAI-style messages ----------
--
-- Chronological, no coalescing. Aborted/error assistants are skipped
-- (matches pi's transform-messages). Orphan tool_use blocks are
-- followed up with synthetic "No result provided" tool messages so
-- the next API turn doesn't reject them.
function M.build_api_messages(session, system_prompt, cfg)
  local tool_result_message = cfg.tool_result_message
  local assistant_tool_call = cfg.assistant_tool_call
  local images_blocked = image_policy.blocked()
  local supports_images = cfg.supports_images and not images_blocked
  local user_image_placeholder = images_blocked and image_policy.DISABLED_TEXT
    or transform.USER_IMAGE_PLACEHOLDER
  local tool_image_placeholder = images_blocked and image_policy.DISABLED_TEXT
    or transform.TOOL_IMAGE_PLACEHOLDER
  local out = prelude.array(#session + 1)
  if system_prompt and system_prompt ~= "" then
    out[#out + 1] = { role = "system", content = clean_text(system_prompt) }
  end
  transform.replay_session(session, {
    user = function(message)
      local content = supports_images and transform.openai_chat_content(message.content)
        or transform.text_from_content_with_image_placeholder(
          message.content,
          user_image_placeholder
        )
      out[#out + 1] = { role = "user", content = prelude.decode_model_value(content) }
    end,
    assistant = function(message)
      local tool_calls = nil
      local pending = prelude.array(#(message.content or {}))
      for _, block in ipairs(message.content or {}) do
        if type(block) == "table" and block.type == "toolCall" then
          tool_calls = tool_calls or prelude.array(1)
          local wire_call = assistant_tool_call(block)
          tool_calls[#tool_calls + 1] = wire_call
          pending[#pending + 1] = { id = wire_call.id, name = wire_call["function"].name }
        end
      end
      local entry = { role = "assistant" }
      local text = clean_text(transform.text_from_content(message.content))
      if text ~= "" then
        entry.content = text
      end
      if tool_calls then
        entry.tool_calls = tool_calls
      end
      out[#out + 1] = entry
      return pending
    end,
    tool_result = function(message)
      local id = message.toolCallId or ""
      local has_images = supports_images and transform.has_images(message.content)
      local text = supports_images and transform.tool_result_text(message)
        or transform.text_from_content_with_image_placeholder(
          message.content,
          tool_image_placeholder
        )
      if text == "" and transform.has_images(message.content) then
        text = "(see attached image)"
      end
      return id,
        {
          message = tool_result_message(id, message.toolName or "", clean_text(text)),
          content = message.content,
          has_images = has_images,
        }
    end,
    tool_results = function(items)
      local image_blocks = prelude.as_array({})
      for _, item in ipairs(items) do
        out[#out + 1] = item.message
        if item.has_images then
          for _, block in ipairs(item.content or {}) do
            if
              type(block) == "table"
              and block.type == "image"
              and type(block.data) == "string"
            then
              image_blocks[#image_blocks + 1] = {
                type = "image_url",
                image_url = {
                  url = "data:"
                    .. tostring(block.mimeType or "application/octet-stream")
                    .. ";base64,"
                    .. block.data,
                },
              }
            end
          end
        end
      end
      if #image_blocks > 0 then
        local content = prelude.as_array({
          { type = "text", text = "Attached image(s) from tool result:" },
        })
        for _, block in ipairs(image_blocks) do
          content[#content + 1] = block
        end
        out[#out + 1] = { role = "user", content = content }
      end
    end,
    synthetic_tool_results = function(calls)
      for _, call in ipairs(calls) do
        out[#out + 1] = tool_result_message(call.id, call.name, "No result provided")
      end
    end,
    compaction_summary = function(summary)
      out[#out + 1] = { role = "user", content = clean_text(summary) }
    end,
    custom_message = function(message)
      local content = supports_images and transform.openai_chat_content(message.content)
        or transform.text_from_content_with_image_placeholder(
          message.content,
          user_image_placeholder
        )
      out[#out + 1] = {
        role = message.role == "assistant" and "assistant" or "user",
        content = prelude.decode_model_value(content),
      }
    end,
  })
  return prelude.as_array(out)
end

-- ---------- Persist assistant + tool_calls in v2 session shape ----------

function M.persist_assistant(state, model, _content, tool_calls, cfg, stop_override, error_message)
  local blocks = prelude.array(#tool_calls + 2)
  -- Reasoning-model thinking (Qwen3, DeepSeek-R1, …) arrives via a
  -- separate field on the wire and is accumulated by the provider's
  -- parser into state.thinking. Persist it as a thinking block so
  -- the session keeps a full record — the Lua-side assistant text
  -- column still tracks only visible content.
  local thinking = state_thinking(state)
  local text = state_text(state)
  if thinking ~= "" then
    blocks[#blocks + 1] = { type = "thinking", thinking = thinking }
  end
  if text ~= "" then
    blocks[#blocks + 1] = { type = "text", text = text }
  end
  for _, tc in ipairs(tool_calls) do
    blocks[#blocks + 1] = {
      type = "tool_use",
      id = tc.id,
      name = tc.name,
      input = tc.arguments,
    }
  end
  local meta = {
    usage = state.usage,
    stop_reason = stop_override or state.stop_reason,
    error_message = error_message,
    model = model,
    provider = cfg.provider_name,
    api = cfg.api_name,
  }
  if cfg.include_response_id then
    meta.response_id = state.response_id
  end
  session_mod.append_assistant(text, blocks, meta)
end

-- ---------- Streaming agent turn ----------
--
-- Generic against the OpenAI-compat request/response flow. Providers
-- own the URL + headers + request body shape + stream parser +
-- delta handler; everything else (the tool loop, the sched
-- round-robin for concurrent dispatch, session persistence, event
-- emission) lives here so a bug fix lands once.
function M.run_turn(opts, cfg)
  cfg.tool_specs = cfg.tool_specs or M.api_tool_specs
  cfg.build_messages = cfg.build_messages or M.build_api_messages
  cfg.finalize = cfg.finalize
    or function(state)
      return nil, cfg.finalize_tool_calls(state)
    end
  cfg.persist = cfg.persist
    or function(state, model, content, tool_calls, stop_override, error_message)
      M.persist_assistant(state, model, content, tool_calls, cfg, stop_override, error_message)
    end
  cfg.has_partial = cfg.has_partial
    or function(state, tool_calls)
      return state_text(state) ~= "" or #tool_calls > 0
    end
  cfg.classify_http_error = cfg.classify_http_error or M.classify_http_error
  cfg.text = cfg.text or state_text
  cfg.after_iteration = cfg.after_iteration or function() end
  return provider_loop.run_turn(opts, cfg)
end

-- ---------- Non-streaming one-shot completion ----------

local http_post_text = sched.http_post_text

local function complete_text_messages(opts)
  return prelude.as_array({
    { role = "system", content = clean_text(opts.system_prompt) },
    { role = "user", content = clean_text(opts.user_text) },
  })
end

function M.complete_text(opts, cfg)
  local body = cfg.request_body({
    model = opts.model or "",
    messages = complete_text_messages(opts),
    tool_specs = prelude.as_array({}),
    max_tokens = opts.max_tokens,
  })
  body.stream = false
  body.tools = nil
  body.stream_options = nil

  local status, response =
    http_post_text(cfg.url, cfg.headers, psi.json_encode(body), opts.abort_check)
  if status == nil then
    local msg = cfg.provider_name .. ": http post failed: " .. tostring(response)
    notice.error(msg)
    return false, msg
  end
  if status < 200 or status >= 300 then
    local msg = M.classify_http_error(status, tostring(response or ""), cfg.provider_name)
    notice.error(msg)
    return false, msg
  end

  local parsed = safe_decode(response)
  if type(parsed) ~= "table" then
    local msg = cfg.provider_name .. ": malformed JSON response"
    notice.error(msg)
    return false, msg
  end
  return true, cfg.extract_completion(parsed)
end

M._debug = {
  complete_text_messages = complete_text_messages,
}

return M
