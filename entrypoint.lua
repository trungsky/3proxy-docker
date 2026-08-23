#!/bin/lua

local CUSTOM_CFG_PATH    = "/etc/3proxy/3proxy.cfg" -- user-provided config, mounted from outside
local GENERATED_CFG_PATH = "/tmp/3proxy.cfg"        -- regenerated from the environment on every start
local MOUNTINFO_PATH     = "/proc/self/mountinfo"
local PROXY_BIN          = "/bin/3proxy"

local ENV_LOG_OUTPUT         = "LOG_OUTPUT"
local ENV_PRIMARY_RESOLVER   = "PRIMARY_RESOLVER"
local ENV_SECONDARY_RESOLVER = "SECONDARY_RESOLVER"
local ENV_MAX_CONNECTIONS    = "MAX_CONNECTIONS"
local ENV_DNS_CACHE_SIZE     = "DNS_CACHE_SIZE"
local ENV_PROXY_LOGIN        = "PROXY_LOGIN"
local ENV_PROXY_PASSWORD     = "PROXY_PASSWORD"
local ENV_PROXY_PORT         = "PROXY_PORT"
local ENV_SOCKS_PORT         = "SOCKS_PORT"
local ENV_EXTRA_ACCOUNTS     = "EXTRA_ACCOUNTS"
local ENV_EXTRA_CONFIG       = "EXTRA_CONFIG"
local ENV_PROXY_EXTRA_ARGS   = "PROXY_EXTRA_ARGS"
local ENV_SOCKS_EXTRA_ARGS   = "SOCKS_EXTRA_ARGS"

-- Returns os.getenv(name), or default when the variable is unset or empty.
--
-- @param name string
-- @param default string
-- @return string
local function getenv(name, default)
  local val = os.getenv(name)
  if val == nil or val == "" then
    return default
  end
  return val
end

-- Writes msg to stderr and exits with code 1. Never returns.
--
-- @param msg string
-- @return never
local function die(msg)
  io.stderr:write("entrypoint: " .. msg .. "\n")
  os.exit(1)
end

-- Strips leading and trailing whitespace.
--
-- @param s string
-- @return string
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Returns true when s is a decimal integer in the range [1, max] (max is optional).
--
-- @param s string
-- @param max? integer
-- @return boolean
local function is_positive_int(s, max)
  local n = tonumber(s)
  if n == nil or math.type(n) ~= "integer" or n < 1 then return false end
  return max == nil or n <= max
end

-- Parses EXTRA_ACCOUNTS value in "login:password;login2:password2" format.
-- Whitespace around separators is stripped. The first colon in each pair separates login from password, so
-- passwords may themselves contain colons.
--
-- @param raw string
-- @return {login: string, password: string}[]
local function parse_extra_accounts(raw)
  local list = {}
  for raw_pair in raw:gmatch("[^;]+") do
    local pair     = trim(raw_pair)
    local colon    = pair:find(":")
    local login    = colon and trim(pair:sub(1, colon - 1))
    local password = colon and trim(pair:sub(colon + 1))
    if login and login ~= "" and password and password ~= "" then
      list[#list + 1] = {login = login, password = password}
    else
      io.stderr:write("entrypoint: ignoring malformed EXTRA_ACCOUNTS pair: '" .. pair .. "'\n")
    end
  end
  return list
end

-- Returns true when path (or its parent directory) is a mount point, false when it is not, or nil
-- when /proc is unavailable and the answer is unknown.
--
-- @param path string
-- @return boolean|nil
local function is_mount_point(path)
  local f = io.open(MOUNTINFO_PATH, "r")
  if not f then return nil end
  local parent = path:match("^(.*)/[^/]+$")
  local found = false
  for line in f:lines() do
    -- mountinfo fields: id parent-id major:minor root MOUNT-POINT options ...
    local mount_point = line:match("^%d+ %d+ %S+ %S+ (%S+)")
    if mount_point == path or mount_point == parent then
      found = true
      break
    end
  end
  f:close()
  return found
end

-- A config mounted from outside wins over the environment. A leftover file that is NOT a mount
-- (e.g. written by an older image version into a persistent root filesystem) must not freeze the
-- configuration, so it is ignored and the config is regenerated from the environment instead.
local cfg_path = GENERATED_CFG_PATH
local custom = io.open(CUSTOM_CFG_PATH, "r")
if custom then
  custom:close()
  if is_mount_point(CUSTOM_CFG_PATH) ~= false then
    cfg_path = CUSTOM_CFG_PATH
  else
    io.stderr:write(
      "entrypoint: ignoring stale " .. CUSTOM_CFG_PATH ..
      " (not a mount point); regenerating config from the environment\n"
    )
  end
end

if cfg_path == GENERATED_CFG_PATH then
  local log_output         = getenv(ENV_LOG_OUTPUT,         "/dev/null")
  local primary_resolver   = getenv(ENV_PRIMARY_RESOLVER,   "1.1.1.1")
  local secondary_resolver = getenv(ENV_SECONDARY_RESOLVER, "8.8.8.8")
  local max_connections    = getenv(ENV_MAX_CONNECTIONS,    "512")
  local dns_cache_size     = getenv(ENV_DNS_CACHE_SIZE,     "512")
  local proxy_login        = getenv(ENV_PROXY_LOGIN,        "")
  local proxy_password     = getenv(ENV_PROXY_PASSWORD,     "")
  local proxy_port         = getenv(ENV_PROXY_PORT,         "8080")
  local socks_port         = getenv(ENV_SOCKS_PORT,         "8081")
  local extra_accounts     = parse_extra_accounts(getenv(ENV_EXTRA_ACCOUNTS, ""))
  local extra_config       = getenv(ENV_EXTRA_CONFIG, ""):gsub("\\n", "\n") -- expand literal \n
  local proxy_extra_args   = getenv(ENV_PROXY_EXTRA_ARGS, "")
  local socks_extra_args   = getenv(ENV_SOCKS_EXTRA_ARGS, "")

  -- validate numeric inputs at the environment boundary
  if not is_positive_int(proxy_port, 65535) then
    die(ENV_PROXY_PORT .. " must be a port number (1-65535), got: " .. proxy_port)
  end
  if not is_positive_int(socks_port, 65535) then
    die(ENV_SOCKS_PORT .. " must be a port number (1-65535), got: " .. socks_port)
  end
  if not is_positive_int(max_connections) then
    die(ENV_MAX_CONNECTIONS .. " must be a positive integer, got: " .. max_connections)
  end
  if not is_positive_int(dns_cache_size) then
    die(ENV_DNS_CACHE_SIZE .. " must be a positive integer, got: " .. dns_cache_size)
  end

  if (proxy_login ~= "") ~= (proxy_password ~= "") then
    io.stderr:write(
      "entrypoint: warning: both " .. ENV_PROXY_LOGIN .. " and " ..
      ENV_PROXY_PASSWORD .. " must be set to enable auth\n"
    )
    proxy_login    = ""
    proxy_password = ""
  end

  local lines = {}

  -- @param s string
  local function toConfig(s) lines[#lines + 1] = s end

  toConfig("#!" .. PROXY_BIN)
  toConfig("")
  -- upstream DNS resolvers for all hostname resolution; up to 5 servers, default port 53/UDP
  toConfig("nserver " .. primary_resolver)
  toConfig("nserver " .. secondary_resolver)
  toConfig("nserver 1.0.0.1")
  toConfig("nserver 8.8.4.4")
  toConfig("nserver 9.9.9.9")
  toConfig("")
  -- DNS response cache table size in entries (min 256); reduces latency and upstream DNS traffic
  toConfig("nscache " .. dns_cache_size)
  toConfig("")
  -- timeouts in seconds (8 positional values):
  --   1    SINGLEBYTE_S: SO_LINGER and single-byte reads on an established connection
  --   5    SINGLEBYTE_L: first byte from client; DNS UDP send/receive
  --   30   STRING_S:     send/read a protocol line (request/response headers, TLS handshake)
  --   60   STRING_L:     wait for server banner or a slow response line
  --   180  CONNECTION_S: idle timeout for short-lived connections (e.g. FTP data channel)
  --   1800 CONNECTION_L: idle timeout for long-lived tunnels (TCP/TLS relay)
  --   15   DNS_TO:       upstream DNS resolver response
  --   60   CHAIN_TO:     handshake with a parent (chained) proxy
  toConfig("timeouts 1 5 30 60 180 1800 15 60")
  toConfig("")
  -- log destination: file path | /dev/stdout | /dev/null | @syslog-tag | &odbc-dsn
  toConfig("log " .. log_output)
  -- log format per connection; specifiers: %t=unix ts, %N=service, %p=port, %E=error code,
  -- %U=user, %C/%c=client ip/port, %R/%r=server ip/port, %O=bytes sent, %I=bytes recv,
  -- %n=target hostname, %T=request text; full list: https://3proxy.org/doc/howtor.html#LOGFORMAT
  toConfig(
    [=[logformat "-\""+_G{""time_unix"":%t,]=] ..
    [=[ ""proxy"":{""type"":""%N"", ""port"":%p},]=] ..
    [=[ ""error"":{""code"":""%E""},]=] ..
    [=[ ""auth"":{""user"":""%U""},]=] ..
    [=[ ""client"":{""ip"":""%C"", ""port"":%c},]=] ..
    [=[ ""server"":{""ip"":""%R"", ""port"":%r},]=] ..
    [=[ ""bytes"":{""sent"":%O, ""received"":%I},]=] ..
    [=[ ""request"":{""hostname"":""%n""},]=] ..
    [=[ ""message"":""%T""}"]=]
  )
  toConfig("")
  -- max simultaneous connections per service; system needs 2×n open file descriptors (ulimit -n)
  toConfig("maxconn " .. max_connections)

  -- CL = cleartext password; alternatives: CR (crypt hash), NT (Windows MD4 hash)
  local users, allowed = {}, {}
  if proxy_login ~= "" then
    users[#users + 1]     = proxy_login .. ":CL:" .. proxy_password
    allowed[#allowed + 1] = proxy_login
  end
  for _, acc in ipairs(extra_accounts) do
    users[#users + 1]     = acc.login .. ":CL:" .. acc.password
    allowed[#allowed + 1] = acc.login
  end

  -- auth is enabled as soon as any account exists: PROXY_LOGIN/PROXY_PASSWORD, EXTRA_ACCOUNTS, or both
  if #users > 0 then
    toConfig("")
    toConfig("users " .. table.concat(users, " "))
    -- require username+password on every connection (vs. iponly / none)
    toConfig("auth strong")
    -- ACL: permit only the listed users; full syntax: allow users src-ip dst-ip dst-port
    toConfig("allow " .. table.concat(allowed, ","))
  end

  if trim(extra_config) ~= "" then
    toConfig("")
    for line in (extra_config .. "\n"):gmatch("([^\n]*)\n") do
      toConfig(line)
    end
  end

  toConfig("")
  -- HTTP/HTTPS CONNECT proxy; -a = anonymous mode (strips X-Forwarded-For etc.), -p = port
  toConfig("proxy -a -p" .. proxy_port .. (proxy_extra_args ~= "" and " " .. proxy_extra_args or ""))
  -- SOCKS4/5 proxy; -a = anonymous mode, -p = port
  toConfig("socks -a -p" .. socks_port .. (socks_extra_args ~= "" and " " .. socks_extra_args or ""))
  toConfig("")
  -- each service (proxy/socks) deep-copies conf.acl at definition time, so flush does not affect
  -- running services; it resets the ACL template for any service defined below and ensures a
  -- clean state when the config is reloaded via SIGHUP
  toConfig("flush")

  -- write config

  local f, open_err = io.open(GENERATED_CFG_PATH, "w")
  if not f then
    die("cannot open " .. GENERATED_CFG_PATH .. ": " .. open_err)
  end

  local write_ok, write_err = f:write(table.concat(lines, "\n"), "\n")
  if not write_ok then
    f:close()
    die("cannot write " .. GENERATED_CFG_PATH .. ": " .. write_err)
  end
  local close_ok, close_err = f:close()
  if not close_ok then
    die("cannot close " .. GENERATED_CFG_PATH .. ": " .. close_err)
  end
end

-- launch 3proxy

-- os.exec replaces the current process image; it never returns on success.
local _, exec_err, exec_code = os.exec(PROXY_BIN, cfg_path)
die(PROXY_BIN .. ": " .. exec_err .. " (errno " .. exec_code .. ")")
