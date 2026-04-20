--[[pod_format="raw",created="2026-04-17 08:32:43",modified="2026-04-19 14:21:35",revision=34]]
window({ width=250, height=160, title="podweb test" })

local markdown_renderer_src = fetch("podnet://48932/podweb-markdown.lua")

-- elaborate fetching to get the latest version of the parser if possible
-- replace with "include podweb-markdown.lua" if it is no longer available
if markdown_renderer_src then
	load(markdown_renderer_src)()
	print("successfully downloaded saturn91 latest parser")
else
	include("podweb-markdown.lua")
	print("fallback to local parser...")
end

local current_url = "podnet://48932/index.podweb"
local document

local function load_page(url)
  local src = fetch(url)
  if src and src ~= "" then
    current_url = url
    document = pdw_parse(src, 200, 100)
  end
end

load_page(current_url)

function _update()
  if not document then return end
  pdw_update(document)
  if document.navigated_to then
    local nav      = document.navigated_to
    local cur_user = string.match(current_url, "podnet://(%d+)/")
    load_page("podnet://" .. (nav.user or cur_user) .. "/" .. nav.file)
  end
end

function _draw()
  cls()
  if document then
    pdw_doc(document, 10, 20)
  end
end