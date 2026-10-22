-- Local throughput comparison only; the official score uses bench/load.js and k6.
local tokens, ids = {}, {500000}
local file = assert(io.open(os.getenv("TOKENS") or "seed/tokens.json"))
for token in file:read("*a"):gmatch('"token"%s*:%s*"([^"]+)"') do tokens[#tokens + 1] = token end
file:close()
assert(#tokens > 0, "no seed tokens found")
local serial = 0
math.randomseed(42)

request = function()
  local r = math.random(217)
  if r <= 100 then return wrk.format("GET", "/feed") end
  local id = ids[math.random(#ids)]
  if r <= 200 then return wrk.format("GET", "/posts/" .. id) end
  local headers = {Authorization = "Bearer " .. tokens[math.random(#tokens)], ["Content-Type"] = "application/json"}
  if r <= 215 then return wrk.format("POST", "/posts/" .. id .. "/like", headers, "") end
  serial = serial + 1
  return wrk.format("POST", "/posts", headers,
    '{"body":"local mixed workload post ' .. serial .. ': measuring fresh writes and reads"}')
end

response = function(status, headers, body)
  if body:sub(1, 10) == '{"posts":[' then
    local latest = {}
    for id in body:gmatch('"id":(%d+)') do latest[#latest + 1] = tonumber(id) end
    if #latest > 0 then ids = latest end
  end
end

-- wrk's stock display omits p95. This callback only reports its histogram;
-- request/response generation and the workload above remain unchanged.
done = function(summary, latency, requests)
  io.write(string.format("  95%% %.6fms\n", latency:percentile(95) / 1000))
end
