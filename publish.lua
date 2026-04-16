--[[pod_format="raw",created="2026-04-16 16:14:15",modified="2026-04-16 16:50:52",revision=63]]
cd(env().path)

local raw1 = env().argv[1]

if raw1 == nil then
    print("execution failed, please provide an filename e.g. index.podnet")
    return
end

local function unquote(s)
    if s == nil then return nil end
    return string.match(s, '^"(.*)"$') or s
end

local arg1 = unquote(pod(raw1))

local target_path = "podnet://48932/" .. arg1
local file_path = env().path .."/" .. arg1
local value = fetch(file_path)

if value == nil then
	print("no file found at: " .. file_path)
	return
end

store(target_path, value)
print(fetch(target_path))
print("exe: ")
print("store("..target_path..",".. arg1 ..")")

