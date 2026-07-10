-- psi.oauth_openai_codex: ChatGPT/OpenAI Codex OAuth flow.
--
-- Ported from pi-mono's packages/ai/src/utils/oauth/openai-codex.ts,
-- but kept Lua-first. The initial psi flow uses manual paste instead
-- of a localhost callback server to avoid new C networking code.

local auth_storage = require("psi.auth_storage")
local prelude = require("psi.prelude")

local M = {}

local PROVIDER = "openai-codex"
local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
local TOKEN_URL = "https://auth.openai.com/oauth/token"
local REDIRECT_URI = "http://localhost:1455/auth/callback"
local SCOPE = "openid profile email offline_access"
local JWT_CLAIM_PATH = "https://api.openai.com/auth"

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local pending_flow = nil

local function rotr(x, n)
  return ((x >> n) | (x << (32 - n))) & 0xffffffff
end

local function sha256_bytes(msg)
  local k = {
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  }
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  msg = msg .. string.char(0x80)
  while (#msg % 64) ~= 56 do
    msg = msg .. "\0"
  end
  local bit_len = len * 8
  msg = msg
    .. string.char(0, 0, 0, 0)
    .. string.char(
      (bit_len >> 24) & 0xff,
      (bit_len >> 16) & 0xff,
      (bit_len >> 8) & 0xff,
      bit_len & 0xff
    )

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local j = chunk + i * 4
      w[i] = (
        (msg:byte(j) << 24)
        | (msg:byte(j + 1) << 16)
        | (msg:byte(j + 2) << 8)
        | msg:byte(j + 3)
      ) & 0xffffffff
    end
    for i = 16, 63 do
      local s0 = rotr(w[i - 15], 7) ~ rotr(w[i - 15], 18) ~ (w[i - 15] >> 3)
      local s1 = rotr(w[i - 2], 17) ~ rotr(w[i - 2], 19) ~ (w[i - 2] >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local ch = (e & f) ~ (~e & g)
      local temp1 = (h + S1 + ch + k[i + 1] + w[i]) & 0xffffffff
      local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (S0 + maj) & 0xffffffff
      h, g, f, e, d, c, b, a =
        g, f, e, (d + temp1) & 0xffffffff, c, b, a, (temp1 + temp2) & 0xffffffff
    end
    h0 = (h0 + a) & 0xffffffff
    h1 = (h1 + b) & 0xffffffff
    h2 = (h2 + c) & 0xffffffff
    h3 = (h3 + d) & 0xffffffff
    h4 = (h4 + e) & 0xffffffff
    h5 = (h5 + f) & 0xffffffff
    h6 = (h6 + g) & 0xffffffff
    h7 = (h7 + h) & 0xffffffff
  end
  local out = {}
  for _, x in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[#out + 1] = string.char((x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff)
  end
  return table.concat(out)
end

local function base64_encode(bytes, alphabet)
  alphabet = alphabet or b64
  local out = {}
  for i = 1, #bytes, 3 do
    local a = bytes:byte(i) or 0
    local b = bytes:byte(i + 1) or 0
    local c = bytes:byte(i + 2) or 0
    local n = (a << 16) | (b << 8) | c
    out[#out + 1] = alphabet:sub(((n >> 18) & 0x3f) + 1, ((n >> 18) & 0x3f) + 1)
    out[#out + 1] = alphabet:sub(((n >> 12) & 0x3f) + 1, ((n >> 12) & 0x3f) + 1)
    out[#out + 1] = i + 1 <= #bytes and alphabet:sub(((n >> 6) & 0x3f) + 1, ((n >> 6) & 0x3f) + 1)
      or "="
    out[#out + 1] = i + 2 <= #bytes and alphabet:sub((n & 0x3f) + 1, (n & 0x3f) + 1) or "="
  end
  return table.concat(out)
end

local function base64url_encode(bytes)
  return (base64_encode(bytes, b64url):gsub("=", ""))
end

local function base64_decode(text)
  text = (text or ""):gsub("-", "+"):gsub("_", "/")
  local pad = #text % 4
  if pad > 0 then
    text = text .. string.rep("=", 4 - pad)
  end
  local map = {}
  for i = 1, #b64 do
    map[b64:sub(i, i)] = i - 1
  end
  local out = {}
  for i = 1, #text, 4 do
    local c1, c2, c3, c4 =
      text:sub(i, i), text:sub(i + 1, i + 1), text:sub(i + 2, i + 2), text:sub(i + 3, i + 3)
    local n = ((map[c1] or 0) << 18)
      | ((map[c2] or 0) << 12)
      | ((map[c3] or 0) << 6)
      | (map[c4] or 0)
    out[#out + 1] = string.char((n >> 16) & 0xff)
    if c3 ~= "=" then
      out[#out + 1] = string.char((n >> 8) & 0xff)
    end
    if c4 ~= "=" then
      out[#out + 1] = string.char(n & 0xff)
    end
  end
  return table.concat(out)
end

local function random_bytes(n)
  if psi.random_bytes then
    local bytes, err = psi.random_bytes(n)
    if bytes then
      return bytes
    end
    return nil, err or "OpenAI Codex OAuth requires a secure random source"
  end
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(n)
    f:close()
    if bytes and #bytes == n then
      return bytes
    end
  end
  return nil, "OpenAI Codex OAuth requires a secure random source"
end

local function urlencode(s)
  return tostring(s):gsub("([^A-Za-z0-9%-%._~])", function(c)
    return string.format("%%%02X", c:byte())
  end)
end

local function form_encode(t)
  local out = {}
  for k, v in pairs(t) do
    out[#out + 1] = urlencode(k) .. "=" .. urlencode(v)
  end
  table.sort(out)
  return table.concat(out, "&")
end

local function parse_query(input)
  local query = tostring(input or ""):match("%?([^#]+)") or tostring(input or "")
  local out = {}
  for k, v in query:gmatch("([^&=?]+)=([^&]*)") do
    v = v:gsub("+", " "):gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
    out[k] = v
  end
  return out
end

local function jwt_payload(token)
  local payload = tostring(token or ""):match("^[^.]+%.([^.]+)%.")
  if not payload then
    return nil
  end
  return prelude.safe_json_decode(base64_decode(payload), nil)
end

local function account_id(access)
  local payload = jwt_payload(access)
  local auth = type(payload) == "table" and payload[JWT_CLAIM_PATH] or nil
  local id = type(auth) == "table" and auth.chatgpt_account_id or nil
  if type(id) == "string" and id ~= "" then
    return id
  end
  return nil
end

local function exchange(body)
  local status, response = psi.http_post(
    TOKEN_URL,
    { "Content-Type: application/x-www-form-urlencoded" },
    form_encode(body)
  )
  if not status then
    return nil, "token request failed: " .. tostring(response)
  end
  if status < 200 or status >= 300 then
    return nil, "token request failed (" .. tostring(status) .. "): " .. tostring(response or "")
  end
  local data = prelude.safe_json_decode(response, nil)
  if
    type(data) ~= "table"
    or type(data.access_token) ~= "string"
    or type(data.refresh_token) ~= "string"
  then
    return nil, "token response missing access_token or refresh_token"
  end
  local id = account_id(data.access_token)
  if not id then
    return nil, "token response did not include chatgpt account id"
  end
  return {
    access = data.access_token,
    refresh = data.refresh_token,
    expires = math.floor(os.time() * 1000) + (tonumber(data.expires_in) or 3600) * 1000,
    accountId = id,
  }
end

function M.create_authorization_flow()
  local verifier_bytes, verifier_err = random_bytes(32)
  if not verifier_bytes then
    return nil, verifier_err
  end
  local state_bytes, state_err = random_bytes(16)
  if not state_bytes then
    return nil, state_err
  end
  local verifier = base64url_encode(verifier_bytes)
  local challenge = base64url_encode(sha256_bytes(verifier))
  local state = base64url_encode(state_bytes)
  local params = form_encode({
    response_type = "code",
    client_id = CLIENT_ID,
    redirect_uri = REDIRECT_URI,
    scope = SCOPE,
    code_challenge = challenge,
    code_challenge_method = "S256",
    state = state,
    id_token_add_organizations = "true",
    codex_cli_simplified_flow = "true",
    originator = "psi",
  })
  return { verifier = verifier, state = state, url = AUTHORIZE_URL .. "?" .. params }
end

function M.exchange_code(code, verifier)
  return exchange({
    grant_type = "authorization_code",
    client_id = CLIENT_ID,
    code = code,
    code_verifier = verifier,
    redirect_uri = REDIRECT_URI,
  })
end

function M.refresh(refresh_token)
  return exchange({
    grant_type = "refresh_token",
    refresh_token = refresh_token,
    client_id = CLIENT_ID,
  })
end

function M.ensure_fresh(entry)
  if type(entry) ~= "table" or entry.type ~= "oauth" then
    return nil, "not logged in"
  end
  if tonumber(entry.expires or 0) > math.floor(os.time() * 1000) + 60000 then
    return entry
  end
  local refreshed, err = M.refresh(entry.refresh)
  if not refreshed then
    return nil, err
  end
  refreshed.type = "oauth"
  local ok, write_err = auth_storage.set(PROVIDER, refreshed)
  if not ok then
    return nil, write_err
  end
  return refreshed
end

function M.credentials()
  local entry = auth_storage.get(PROVIDER)
  return M.ensure_fresh(entry)
end

-- Presence check only; never refreshes tokens, so the resolver's auth
-- gate can call it without network I/O.
function M.has_credentials()
  local entry = auth_storage.get(PROVIDER)
  return type(entry) == "table" and entry.type == "oauth" and type(entry.refresh) == "string"
end

function M.login_with_input(input, flow)
  flow = flow or pending_flow
  if type(flow) ~= "table" or type(flow.verifier) ~= "string" then
    return nil, "no pending login; run /login openai-codex first"
  end
  local parsed = parse_query(input)
  if parsed.state and parsed.state ~= flow.state then
    return nil, "OAuth state mismatch"
  end
  local code = parsed.code
  if not code or code == "" then
    code = tostring(input or ""):match("^%s*(.-)%s*$")
  end
  if not code or code == "" then
    return nil, "missing authorization code"
  end
  local creds, err = M.exchange_code(code, flow.verifier)
  if not creds then
    return nil, err
  end
  creds.type = "oauth"
  local ok, write_err = auth_storage.set(PROVIDER, creds)
  if not ok then
    return nil, write_err
  end
  if pending_flow == flow then
    pending_flow = nil
  end
  return creds
end

function M.begin_login()
  local flow, err = M.create_authorization_flow()
  if not flow then
    return nil, err
  end
  pending_flow = flow
  return pending_flow
end

function M.finish_login(input)
  local creds, err = M.login_with_input(input, pending_flow)
  if not creds then
    return false, err
  end
  return true, "authenticated openai-codex account " .. tostring(creds.accountId)
end

function M.login_interactive()
  local flow, err = M.begin_login()
  if not flow then
    return false, err
  end
  io.write("Open this URL in your browser:\n\n" .. flow.url .. "\n\n")
  io.write("Paste the final redirect URL or authorization code: ")
  local input = io.read("*l") or ""
  return M.finish_login(input)
end

M._debug = {
  sha256_bytes = sha256_bytes,
  base64url_encode = base64url_encode,
  base64_decode = base64_decode,
  urlencode = urlencode,
  parse_query = parse_query,
}

return M
