--[[pod_format="raw",created="2026-04-24 07:01:30",modified="2026-04-24 07:39:18",revision=51]]
base_url = "podnet://".. stat(64)

files = ls(base_url)

tot_size = 0

for f in all(files) do
	name, size =fstat(base_url .. "/" .. f)
	tot_size += size
end

-- print bar
local bar_w = 50
local MB = 100000
local kB = 1000
local MB_64 = 64 * MB
local fill_rate = tot_size / MB_64
local used_bar = ceil(fill_rate * bar_w)
local percentage = ceil(fill_rate * 100)
local bar = ""

for i=1, bar_w do
	if i <= used_bar then
		bar = bar .. "#"
	else
		bar = bar .. "."
	end
end

function format_number(num)
	if num > MB then
		return ceil(num/MB) .. "MB"
	end
	
	if num > kB then
		return ceil(num/kB) .. "kB"
	end
	
	return num .. "B"
end

print("your podnet storage: " .. base_url)
print("you are using : " .. format_number(tot_size) .. " of " .. format_number(MB_64) .. " which is " .. percentage .. "%")
print(".")
print(bar)
print(".")
