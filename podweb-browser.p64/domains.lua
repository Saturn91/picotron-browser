--[[pod_format="raw",created="2026-04-20 20:17:56",modified="2026-04-20 21:08:15",revision=1,xstickers={}]]
-- Manages the local domain-to-user-id lookup table, persisted to podnet

known_domains = {}

local function clean_str(s)
  return (string.gsub(string.gsub(s, "\r", ""), "\n", ""))
end

function load_known_domains()
  local src = fetch(DOMAINS_FILE)
  if src and src ~= "" then
    local raw = unpod(src) or {}
    known_domains = {}
    for domain, uid in pairs(raw) do
      known_domains[clean_str(domain)] = uid
    end
  end
end

function save_known_domains()
  store(DOMAINS_FILE, pod(known_domains))
end

function register_domain_if_new(domain, user_id)
  if user_id and not known_domains[domain] then
    known_domains[domain] = user_id
    save_known_domains()
  end
end

function resolve_url(input)
  if string.match(input, "^#?[%w_]+%.p64$") then return input end
  if string.match(input, "^podnet://") then return input end
  if string.match(input, "^https?://") then
    if not string.match(input, "^https?://[^/]+/.+") then
      return string.gsub(input, "/?$", "/index.podweb")
    end
    return input
  end
  local domain, file = string.match(input, "^([^/]+)/(.+)")
  if not domain then
    domain = input
    file   = "index.podweb"
  end
  local addr = known_domains[domain]
  if addr then
    if string.match(addr, "^https?://") then
      return addr .. "/" .. file
    end
    return "podnet://" .. addr .. "/" .. file
  end
  return nil
end
