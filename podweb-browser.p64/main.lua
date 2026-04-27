--[[pod_format="raw",created="2026-04-17 09:53:00",modified="2026-04-27 14:53:52",revision=118,xstickers={}]]
-- Podweb Browser v0.3 - entry point, state, and lifecycle
include("config.lua")
include("domains.lua")
include("renderer.lua")

function get_start_page()
	if env().url then 	return  env().url end
	if #env().argv == 1 then return env().argv[1] end
  	
  	return HOME_URL
end

function set_conf(option, value)
	conf[option] = value
	store(CONFIG_FILE, pod(conf))
end

function push_history(url)
  while #history > hist_idx do
    table.remove(history)
  end
  add(history, url)
  while #history > 10 do
    table.remove(history, 1)
  end
  hist_idx = #history
end

function navigate_to(url)
  if string.match(url, "^#?[%w_]+%.p64$") then
    local id = string.match(url, "^#?(.+)$")
    create_process("bbs://" .. id)
    return
  end
  push_history(url)
  current_url = url
  load_page()
end

function go_back()
  if hist_idx > 1 then
    hist_idx   -= 1
    current_url = history[hist_idx]
    load_page()
  end
end

function go_forward()
  if hist_idx < #history then
    hist_idx   += 1
    current_url = history[hist_idx]
    load_page()
  end
end

local CONT_Y = BAR_H + 1
CONT_H = H - BAR_H - 1

local loading         = false
local loading_co      = nil
local load_started_at = 0
local MIN_LOAD_FRAMES = 30  -- 0.5s at 60fps

local function create_url_bar(display_text)
  gui     = create_gui()
  url_bar = gui:attach_text_editor{
    x      = RELOAD_BTN.x + RELOAD_BTN.w + 4,
    y      = 2,
    width  = COPY_BTN.x - (RELOAD_BTN.x + RELOAD_BTN.w + 4) - 4,
    height = BAR_H - 4,
    key_callback = {
      ["enter"] = function(self, k)
        local input = self:get_text()[1]
        if input and input ~= "" then
          navigate_to(resolve_url(input) or input)
        end
        return nil
      end
    }
  }
  if url_bar.set_text and display_text then
    url_bar:set_text(display_text)
  end
end

local function check_resize()
  local nw = get_display():width()
  local nh = get_display():height()
  if nw ~= W or nh ~= H then
    W, H         = nw, nh
    CONT_H       = H - BAR_H - 1
    COPY_BTN.x   = W - 32
    SUBMIT_BTN.x = W - 16
    local cur_text = url_bar and url_bar.get_text and url_bar:get_text()[1]
    create_url_bar(cur_text or current_url)
    if current_url then load_page() end
  end
end

local ERROR_PAGE = [[
[p] ------------------------------------
[h1] Nothing is here.
[h2] Or how the world wide web would say
[img url=podnet://48932/404.gfx]
[p] Did you mistype? Then check the url.
[p] Did you come here via a link? Let the owner of the containing page know that their link is broken.
[p] ---------------------------------------
]]

local function do_load_page()
  document = nil
  local src, err = fetch(current_url)
  yield()
  if src and src ~= "" then
    document = pdw_parse(src, W, CONT_H)
    yield()
    if #document.items == 0 then
      document = pdw_parse(ERROR_PAGE, W, CONT_H)
      if url_bar and url_bar.set_text then url_bar:set_text(current_url) end
    else
      local meta = document.meta
      if meta.domain then
        local uid = string.match(current_url, "podnet://(%d+)/")
                 or string.match(current_url, "^(https?://[^/]+)")
        register_domain_if_new(meta.domain, uid)
      end
      local uid            = string.match(current_url, "podnet://(%d+)/")
                          or string.match(current_url, "^(https?://[^/]+)")
      local display_domain = meta.domain
      if display_domain and known_domains[display_domain] ~= nil
         and known_domains[display_domain] ~= uid then
        display_domain = nil
      end
      if not display_domain then
        for domain, id in pairs(known_domains) do
          if id == uid then display_domain = domain; break end
        end
      end
      local path = string.match(current_url, "podnet://%d+/(.+)")
                or string.match(current_url, "^https?://[^/]+/(.+)")
                or ""
      local display = display_domain
        and (display_domain .. "/" .. path)
        or  current_url
      if url_bar and url_bar.set_text then url_bar:set_text(display) end
    end
  else
    document = pdw_parse(ERROR_PAGE, W, CONT_H)
    if url_bar and url_bar.set_text then url_bar:set_text(current_url) end
  end
  while popup_frame - load_started_at < MIN_LOAD_FRAMES do
    yield()
  end
  loading = false
end

function load_page()
  loading         = true
  load_started_at = popup_frame
  loading_co      = cocreate(do_load_page)
end

local function draw_loading()
  local step  = (flr(popup_frame / 10) % 3) + 1
  local msg   = "Loading" .. string.rep(".", step)
  local pad_x = 10
  local pad_y = 6
  local tw    = print("Loading...", 0, -100)
  local bw    = tw + pad_x * 2
  local bh    = 5  + pad_y * 2
  local cx    = flr(W / 2)
  local cy    = flr((CONT_Y + H) / 2)
  local bx    = cx - flr(bw / 2)
  local by    = cy - flr(bh / 2)
  rectfill(bx, by, bx + bw, by + bh, 0)
  rect    (bx, by, bx + bw, by + bh, 7)
  print(msg, bx + pad_x, by + pad_y, 7)
end

-- -- popup system ---------------------------------------------------------------

local POPUP_PAD_X  = 6
local POPUP_PAD_Y  = 3
local POPUP_H      = 5 + POPUP_PAD_Y * 2
local POPUP_RIGHT  = 4
local POPUP_BOTTOM = 2
local POPUP_GAP    = 2
local POPUP_MAX    = 10

popup_list  = {}
popup_frame = 0

function popup(text, duration)
  if #popup_list >= POPUP_MAX then
    table.remove(popup_list, 1)
  end
  local frames = (duration or 5) * 60
  add(popup_list, { text=text, expires=popup_frame + frames })
end

local function update_popups()
  popup_frame += 1
  local i = 1
  while i <= #popup_list do
    if popup_list[i].expires <= popup_frame then
      table.remove(popup_list, i)
    else
      i += 1
    end
  end
end

local function draw_popups()
  local base = H - POPUP_BOTTOM
  
  for i = #popup_list, 1, -1 do
    local p  = popup_list[i]
    local tw = print(p.text, 0, -20)
    local pw = tw + POPUP_PAD_X * 2
    local px = W - pw - POPUP_RIGHT
    local py = base - POPUP_H
    rectfill(px-1, py-1, px+pw, py+POPUP_H, 0)
    rect    (px-1, py-1, px+pw, py+POPUP_H, 5)
    print(p.text, px + POPUP_PAD_X, py + POPUP_PAD_Y, 7)
    base = py - POPUP_GAP
  end
end

-- -- lifecycle ------------------------------------------------------------------

function _init()
  
	if fstat("/appdata/podweb-browser") == nil then
		mkdir("/appdata/podweb-browser")
	end
	if fstat("/appdata/podweb-browser/downloads") == nil then
		mkdir("/appdata/podweb-browser/downloads")
	end
	config_file_contents = fetch(CONFIG_FILE)
	if config_file_contents ~= nil then
		conf = unpod(config_file_contents)
	else
		conf = {
			fullscreen = true
		}
		store(CONFIG_FILE, pod(conf))
	end

	if conf.fullscreen then
		W = 480
		H = 270
		win_data = { title="Podweb Browser v" .. VERSION, tabbed=true}
	else
		win_data = { width=W, height=H, title="Podweb Browser v" .. VERSION}
	end
  window(win_data)
  
	if conf.fullscreen then
		fullscreen_menu_label = "Restart in windowed mode"
	else
		fullscreen_menu_label = "Restart in fullscreen mode"
	end
  
  menuitem {
		id = 1,
		label = fullscreen_menu_label,
		action = function()
				set_conf("fullscreen", not conf.fullscreen)
				notify("Restarting to apply changes...")
				exit()
			end
	}

  include("podweb-markdown.lua")
  
  current_url = get_start_page()

  document    = nil
  url_bar     = nil
  prev_mb     = 0
  history     = {}
  hist_idx    = 0

  load_known_domains()
  popup("Welcome to Podweb Browser v" .. VERSION)
  create_url_bar(current_url)
  push_history(current_url)
  load_page()
end

function _update()
  check_resize()

  if loading then
    if loading_co and costatus(loading_co) ~= "dead" then
      coresume(loading_co)
    else
      loading = false
    end
    gui:update_all()
    update_popups()
    return
  end

  if document then
    pdw_update(document)
    if document.copied then
      popup("copied to clipboard", 3)
    end
    if document.navigated_to then
      local nav = document.navigated_to
      if nav.url then
        navigate_to(nav.url)
      elseif nav.cart then
        local url = "bbs://" .. nav.cart .. ".p64"
        create_process(url)
        popup("running cart: " .. url)
      else
        local cur_user = string.match(current_url, "podnet://(%d+)/")
        navigate_to("podnet://" .. (nav.user or cur_user) .. "/" .. (nav.file or "index.podweb"))
      end
    end
    if document.download_requested then
      local req      = document.download_requested
      local fetch_url = string.gsub(req.url, "^podweb://", "podnet://")
      local content  = fetch(fetch_url)
      local dest     = "/appdata/podweb-browser/downloads/" .. req.filename
      if content then
        store(dest, content)
        popup("downloaded to " .. dest, 6)
      else
        popup("download failed: " .. req.filename, 4)
      end
    end
  end

  local _, _, mb = mouse()
  if (prev_mb & 1) == 1 and (mb & 1) == 0 then
    if is_over_button(RELOAD_BTN) then load_page() end
    if is_over_button(BACK_BTN)    then go_back() end
    if is_over_button(FORWARD_BTN) then go_forward() end
    if is_over_button(COPY_BTN) then
      set_clipboard(current_url)
      popup("copied to clipboard", 3)
    end
    if is_over_button(SUBMIT_BTN) then
      local input = url_bar:get_text()[1]
      if input and input ~= "" then
        navigate_to(resolve_url(input) or input)
      end
    end
  end
  prev_mb = mb
  gui:update_all()
  update_popups()
end

function _draw()
  cls(1)
  draw_address_bar()
  if document then pdw_doc(document, 0, CONT_Y) end
  gui:draw_all()
  draw_popups()
  if loading then draw_loading() end
end