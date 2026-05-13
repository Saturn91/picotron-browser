--[[pod_format="raw",created="2026-04-17 08:26:09",modified="2026-05-03 07:49:59",revision=45,xstickers={}]]
-- podweb-markdown.lua
-- API: pdw_parse(src, width, height) -> document, max_scroll
--      pdw_update(document)          -> handles scrolling, links, copy
--      pdw_doc(document, x, y)       -> renders document with scrollbar
--
-- After pdw_update, check document.navigated_to = {user, file} for link clicks.
-- It is reset automatically at the start of the next pdw_update call.
--
-- Font syntax in .podweb files:
--   [font id=myid url=podnet://xxxxx/myfont.font height=10]
--   [h2 font=myid] heading    [p font=myid] inline    [p- font=myid] ... [-p]
--   [link file=x.podweb font=myid] label    (code blocks always use mono font)

local CHAR_W   = 4
local PAD_X    = 6
local SCROLL_W = 4

local CMT_AVAT    = 16
local CMT_PAD     = 4
local CMT_VPAD    = 4
local CMT_HEAD_H  = LINE_H + 6
local CMT_INPUT_H = 16

local WEBRING_BTN_W   = 44
local WEBRING_BTN_H   = 13
local WEBRING_BTN_GAP = 10

local AUDIO_W       = 100
local AUDIO_H       = 13
local AUDIO_R       = 6
local AUDIO_BTN_Y   = 4          -- (AUDIO_H - 5) / 2
local AUDIO_INNER_X = AUDIO_R + 3  -- 9: inner left offset
local AUDIO_REW_X   = AUDIO_INNER_X          -- 9  (5px wide)
local AUDIO_PLAY_X  = AUDIO_INNER_X + 7      -- 16 (4px wide)
local AUDIO_STOP_X  = AUDIO_INNER_X + 13     -- 22 (4px wide)
local AUDIO_PROG_X  = AUDIO_INNER_X + 20     -- 29
local AUDIO_PROG_W  = AUDIO_W - AUDIO_PROG_X - AUDIO_R - 3  -- 62

local _audio_playing   = nil   -- url of currently playing audio
local _audio_play_time = 0

local GRID_PAD = 2
local GRID_GAP = 4

-- font system

local _default_font = fetch("/system/fonts/lil.font")
local _mono_font    = fetch("/system/fonts/lil_mono.font")
local _font_reg     = {}

local LINE_H      = 10
local MONO_LINE_H = 10

local H1_FONT_H    = 10
local _h1_font_raw = fetch("podnet://78402/fonts/lilwide.font")
local _h1_font     = type(_h1_font_raw) == "userdata" and _h1_font_raw or nil
local H1_LINE_H    = _h1_font and (H1_FONT_H + 2) or LINE_H

local function _apply_font(id)
  if id == "mono" then
    _mono_font:poke(0x4000)
  elseif id == "__h1" then
    (_h1_font or _default_font):poke(0x4000)
  elseif id and _font_reg[id] then
    _font_reg[id].data:poke(0x4000)
  else
    _default_font:poke(0x4000)
  end
end

local function _item_line_h(font_id)
  if font_id == "mono"  then return MONO_LINE_H
  elseif font_id == "__h1" then return H1_LINE_H
  elseif font_id and _font_reg[font_id] then return _font_reg[font_id].line_h
  else return LINE_H end
end

-- text helpers

local function measure(s)
  return print(s, 0, -20)
end

local function wrap_text(text, max_w)
  local words, wrapped, current = {}, {}, ""
  for word in string.gmatch(text, "%S+") do add(words, word) end
  for _, word in ipairs(words) do
    local candidate = current == "" and word or (current .. " " .. word)
    if measure(candidate) <= max_w then
      current = candidate
    else
      if current ~= "" then add(wrapped, current) end
      current = word
    end
  end
  if current ~= "" then add(wrapped, current) end
  if #wrapped == 0 then add(wrapped, "") end
  return wrapped
end

local function parse_inline(text)
  local spans, pos = {}, 1
  while pos <= #text do
    local ll, le_l, al, il = string.find(text, "%[link%-([^%]]*)%](.-)%[%-link%]", pos)
    local ld, le_d, ad     = string.find(text, "%[download ([^%]]*)%]", pos)
    local ls, le, attrs, inner, is_dl
    if ll and (not ld or ll <= ld) then
      ls, le, attrs, inner, is_dl = ll, le_l, al, il, false
    elseif ld then
      ls, le, attrs, is_dl = ld, le_d, ad, true
    end
    if not ls then
      local tail = string.sub(text, pos)
      if tail ~= "" then add(spans, { type="text", text=tail }) end
      break
    end
    if ls > pos then add(spans, { type="text", text=string.sub(text, pos, ls-1) }) end
    if is_dl then
      local url         = string.match(attrs, 'url="([^"]+)"') or string.match(attrs, "url=([^%s%]\"]+)")
      local filename    = url and (string.match(url, "/([^/]+)$") or url) or "file"
      local color       = tonumber(string.match(" " .. attrs, "[^%w_]color=(%d+)"))
      local hover_color = tonumber(string.match(attrs, "hover_color=(%d+)"))
      add(spans, { type="download", text="download '" .. filename .. "'", url=url, filename=filename, color=color, hover_color=hover_color })
    else
      local url         = string.match(attrs, 'url="([^"]+)"') or string.match(attrs, "url=([^%s%]\"]+)")
      local user        = not url and string.match(attrs, "user=(%d+)")
      local file        = not url and attrs and string.match(attrs, "file=(%S+)")
      local cart        = not url and attrs and string.match(attrs, "cart=#?([^%s%]]+)")
      local color       = tonumber(string.match(" " .. attrs, "[^%w_]color=(%d+)"))
      local hover_color = tonumber(string.match(attrs, "hover_color=(%d+)"))
      add(spans, { type="link", text=inner, url=url, user=user, file=file, cart=cart, color=color, hover_color=hover_color })
    end
    pos = le + 1
  end
  return spans
end

local function wrap_spans(spans, max_w)
  local toks = {}
  for _, span in ipairs(spans) do
    local lnk = span.type == "link"     and span or nil
    local dl  = span.type == "download" and span or nil
    for word in string.gmatch(span.text, "%S+") do
      add(toks, { text=word, link=lnk, dl=dl })
    end
  end
  if #toks == 0 then return {{}} end
  local lines, cur, cur_w = {}, {}, 0
  local function push(text, link, dl)
    local last = cur[#cur]
    if last and last.link == link and last.dl == dl then last.text ..= text
    else add(cur, { text=text, link=link, dl=dl }) end
  end
  for _, tok in ipairs(toks) do
    local tw = measure(tok.text)
    local sw = cur_w > 0 and measure(" ") or 0
    if cur_w > 0 and cur_w + sw + tw > max_w then
      add(lines, cur) ; cur, cur_w, sw = {}, 0, 0
    end
    if sw > 0 then
      local last = cur[#cur]
      if last then last.text ..= " " end
    end
    push(tok.text, tok.link, tok.dl)
    cur_w += sw + tw
  end
  if #cur > 0 then add(lines, cur) end
  if #lines == 0 then add(lines, {}) end
  return lines
end

-- comment helpers

local function DateToUnix(d)
  local start, _, year, month, day, hour, minute, second = d:find("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
  if start then
    local tm_year = tonum(year) - 1900
    local month   = tonum(month)
    local day     = tonum(day)
    local tm_hour = tonum(hour)
    local tm_min  = tonum(minute)
    local tm_sec  = tonum(second)
    local tm_yday   = -1
    local isLeapYear = ((tonum(year) % 4 == 0) and (tonum(year) % 100 ~= 0)) or (tonum(year) % 400 == 0)
    for m = 1, month - 1 do
      if m == 2 then
        tm_yday += isLeapYear and 29 or 28
      elseif m == 4 or m == 6 or m == 9 or m == 11 then
        tm_yday += 30
      else
        tm_yday += 31
      end
    end
    tm_yday += day
    return tm_sec + tm_min * 60 + tm_hour * 3600 + tm_yday * 86400 +
      (tm_year - 70) * 31536000 + ((tm_year - 69) // 4) * 86400 -
      ((tm_year - 1) // 100) * 86400 + ((tm_year + 299) // 400) * 86400
  end
  return nil
end

local function make_table_name(url)
  local s = string.match(url, "^podnet://(.+)") or url
  s = string.gsub(string.lower(s), "[^%a%d]", "_")
  return string.sub("podweb_" .. s, 1, 40)
end

local function layout_comment_entries(entries, text_w)
  _apply_font(nil)
  local valid = {}
  for _, e in ipairs(entries) do
    if e.extra and e.extra ~= "" then
      local ts_str, text = string.match(e.extra, "^([^|]+)|(.+)")
      if ts_str and text then
        local ts_num = tonumber(ts_str) or DateToUnix(ts_str)
        add(valid, { e=e, ts=ts_num or 0, ts_raw=not ts_num and ts_str or nil, text=text })
      end
    end
  end
  for i = 2, #valid do
    local v = valid[i]
    local j = i - 1
    while j >= 1 and valid[j].ts > v.ts do
      valid[j + 1] = valid[j]
      j -= 1
    end
    valid[j + 1] = v
  end
  for _, p in ipairs(valid) do
    local disp = p.ts_raw or date("%Y-%m-%d %H:%M:%S", p.ts)
  end
  local laid, cy = {}, 0
  for _, p in ipairs(valid) do
    local wrapped    = wrap_text(p.text, text_w)
    local h          = CMT_VPAD + max(CMT_AVAT, LINE_H + #wrapped * LINE_H) + CMT_VPAD
    local disp_date  = p.ts_raw or date("%Y-%m-%d %H:%M:%S", p.ts)
    add(laid, { user=p.e.username, user_id=p.e.user_id, date=disp_date, lines=wrapped, cy=cy, h=h, icon=p.e.icon, score=p.e.score })
    cy += h + 1
  end
  return laid, cy
end

-- parser

local function parse_attrs(s)
  return {
    font  = string.match(s, "font=([%w_%-]+)"),
    align = string.match(s, "align=(%a+)"),
    color = tonumber(string.match(s, "color=(%d+)")),
  }
end

local function parse_podweb(src)
  local nodes, lines, meta, theme = {}, {}, {}, {}
  src = string.gsub(src, "^%-%-%[%[.-%]%]", "")
  for line in string.gmatch(src .. "\n", "([^\n]*)\n") do add(lines, (string.gsub(line, "\r$", ""))) end

  local i = 1
  while i <= #lines do
    local l = lines[i]

    if string.match(l, "^%[meta%-%]") then
      i += 1
      while i <= #lines and not string.match(lines[i], "^%[%-meta%]") do
        local key, val = string.match(lines[i], "^(%w+):%s*(.+)")
        if key then meta[key] = val end
        i += 1
      end
      i += 1

    elseif string.match(l, "^%[theme%-%]") then
      i += 1
      while i <= #lines and not string.match(lines[i], "^%[%-theme%]") do
        local key, val = string.match(lines[i], "^([%w_]+)=(%d+)$")
        if key and DEFAULT_COLORS[key] ~= nil then
          theme[key] = tonumber(val)
        end
        i += 1
      end
      i += 1

    elseif string.match(l, "^%[font ") then
      local id     = string.match(l, "id=([%w_%-]+)")
      local url    = string.match(l, "url=([^%s%]]+)")
      local height = tonumber(string.match(l, "height=(%d+)"))
      if id and url then
        add(nodes, { tag="font_def", id=id, url=url, height=height })
      end
      i += 1

    elseif string.match(l, "^%[grid%-") then
      local tag_part = string.match(l, "^%[([^%]]+)%]")
      local cols = {}
      for c in string.gmatch(string.match(tag_part, "columns=([%w%;]+)") or "", "([^;]+)") do
        add(cols, tonumber(c) or c)
      end
      if #cols == 0 then add(cols, "auto") end
      local parts = {}
      i += 1
      while i <= #lines and lines[i] ~= "[-grid]" do
        add(parts, lines[i])
        i += 1
      end
      local inner_src = ""
      for j, p in ipairs(parts) do
        inner_src = j == 1 and p or (inner_src .. "\n" .. p)
      end
      local child_nodes = parse_podweb(inner_src)
      add(nodes, {
        tag      = "grid",
        columns  = cols,
        children = child_nodes,
        gap      = tonumber(string.match(tag_part, "[^%a]gap=(%d+)") or string.match(tag_part, "^gap=(%d+)")),
        gap_x    = tonumber(string.match(tag_part, "gapX=(%d+)")),
        gap_y    = tonumber(string.match(tag_part, "gapY=(%d+)")),
      })
      i += 1

    elseif string.match(l, "^%[[%a%d]+%-[^%]]*%]") then
      local tag_part = string.match(l, "^%[([^%]]+)%]")
      local tag      = string.lower(string.match(tag_part, "^([%a%d]+)%-"))
      local attrs    = parse_attrs(tag_part)
      local close    = "[-" .. tag .. "]"
      local parts    = {}
      i += 1
      while i <= #lines and lines[i] ~= close do
        add(parts, lines[i])
        i += 1
      end
      local text = ""
      if tag == "code" then
        for j, p in ipairs(parts) do text = j == 1 and p or (text .. "\n" .. p) end
      else
        for _, p in ipairs(parts) do
          if p ~= "" then text = text == "" and p or (text .. " " .. p) end
        end
      end
      if tag == "p" and (string.find(text, "%[link%-") or string.find(text, "%[download ")) then
        add(nodes, { tag=tag, spans=parse_inline(text), font=attrs.font, align=attrs.align, color=attrs.color })
      else
        add(nodes, { tag=tag, text=text, font=attrs.font, align=attrs.align, color=attrs.color })
      end
      i += 1

    elseif string.match(l, "^%[img") then
      local url = string.match(l, "url=([^%s%]]+)")
      local alt = string.match(l, "alt=([^%]]+)")
      if alt then alt = string.match(alt, "^%s*(.-)%s*$") end
      local align  = string.match(l, "align=(%a+)")
      local resize = string.match(l, "resize=(%a+)")
      local vp_str   = string.match(l, "viewport=([%d_;]+)")
      local cut_w, cut_h = string.match(l, "cut=(%d+)_(%d+)")
      local anim_frames  = tonumber(string.match(l, "frames=(%d+)")) or 15
      local img_scale    = tonumber(string.match(l, "scale=([%d%.]+)")) or 1
      local viewports = {}
      if vp_str then
        for entry in string.gmatch(vp_str, "[^;]+") do
          local x, y = string.match(entry, "(%d+)_(%d+)")
          if x then add(viewports, { tonumber(x), tonumber(y) }) end
        end
      end
      if cut_w then cut_w, cut_h = tonumber(cut_w), tonumber(cut_h) end
      if url then add(nodes, { tag="img", url=url, alt=alt or url, align=align, resize=resize, viewports=viewports, cut_w=cut_w, cut_h=cut_h, anim_frames=anim_frames, img_scale=img_scale }) end
      i += 1

    elseif string.match(l, "^%[break") then
      local h = tonumber(string.match(l, "height=(%d+)")) or LINE_H
      add(nodes, { tag="break", height=h })
      i += 1

    elseif string.match(l, "^%[comments") then
      local h = tonumber(string.match(l, "height=(%d+)")) or 140
      add(nodes, { tag="comments", height=h,
        btn_bg           = tonumber(string.match(l, "btn_bg=(%d+)")),
        btn_bg_hover     = tonumber(string.match(l, "btn_bg_hover=(%d+)")),
        btn_border       = tonumber(string.match(l, "btn_border=(%d+)")),
        btn_border_hover = tonumber(string.match(l, "btn_border_hover=(%d+)")),
        btn_text         = tonumber(string.match(l, "btn_text=(%d+)")),
      })
      i += 1

    elseif string.match(l, "^%[webring ") then
      local ring_url = string.match(l, "ring%-data=([^%s%]]+)")
      if ring_url then
        add(nodes, { tag="webring", ring_url=ring_url,
          btn_bg           = tonumber(string.match(l, "btn_bg=(%d+)")),
          btn_bg_hover     = tonumber(string.match(l, "btn_bg_hover=(%d+)")),
          btn_border       = tonumber(string.match(l, "btn_border=(%d+)")),
          btn_border_hover = tonumber(string.match(l, "btn_border_hover=(%d+)")),
          btn_text         = tonumber(string.match(l, "btn_text=(%d+)")),
        })
      end
      i += 1

    elseif string.match(l, "^%[audio") then
      local url = string.match(l, "url=([^%s%]]+)")
      if url then add(nodes, { tag="audio", url=url }) end
      i += 1

    elseif string.match(l, "^%[download ") then
      local url = string.match(l, "url=([^%s%]]+)")
      if url then
        local filename    = string.match(url, "/([^/]+)$") or url
        local align       = string.match(l, "align=(%a+)")
        local color       = tonumber(string.match(" " .. l, "[^%w_]color=(%d+)"))
        local hover_color = tonumber(string.match(l, "hover_color=(%d+)"))
        add(nodes, { tag="download", url=url, filename=filename, align=align, color=color, hover_color=hover_color })
      end
      i += 1

    elseif string.match(l, "^%[link") then
      local attrs = string.match(l, "^%[link([^%]]*)%]")
      local text  = string.match(l, "^%[link[^%]]*%] (.+)")
      if text then
        local url   = attrs and (string.match(attrs, 'url="([^"]+)"') or string.match(attrs, 'url=([^%s%]"]+)'))
        local cart  = not url and attrs and string.match(attrs, "cart=#?([^%s%]]+)")
        local font  = attrs and string.match(attrs, "font=([%w_%-]+)")
        local align = attrs and string.match(attrs, "align=(%a+)")
        add(nodes, {
          tag   = "link",
          text  = text,
          url   = url,
          user  = not url and not cart and attrs and string.match(attrs, "user=(%d+)"),
          file  = not url and not cart and attrs and string.match(attrs, "file=(%S+)"),
          cart  = cart,
          font  = font,
          align = align,
          color       = attrs and tonumber(string.match(" " .. (attrs or ""), "[^%w_]color=(%d+)")),
          hover_color = attrs and tonumber(string.match(attrs, "hover_color=(%d+)")),
        })
      end
      i += 1

    elseif string.match(l, "^%[[%a%d]+[^%]]*%] .+") then
      local tag_part = string.match(l, "^%[([^%]]+)%]")
      local tag      = string.lower(string.match(tag_part, "^([%a%d]+)"))
      local text     = string.match(l, "^%[[^%]]+%] (.+)")
      local attrs    = parse_attrs(tag_part)
      if tag == "p" and (string.find(text, "%[link%-") or string.find(text, "%[download ")) then
        add(nodes, { tag=tag, spans=parse_inline(text), font=attrs.font, align=attrs.align, color=attrs.color })
      else
        add(nodes, { tag=tag, text=text, font=attrs.font, align=attrs.align, color=attrs.color })
      end
      i += 1

    else
      i += 1
    end
  end

  return nodes, meta, theme
end

-- layout

local function calc_x_start(align, text_w, cont_w, pad)
  pad = pad or PAD_X
  if align == "center" then return pad + flr((cont_w - text_w) / 2)
  elseif align == "right" then return pad + cont_w - text_w
  else return pad end
end

local function extract_sprite(raw)
  if type(raw) == "userdata" then return raw end
  if type(raw) ~= "table"    then return nil end
  if raw[1] and type(raw[1]) == "table" and type(raw[1].bmp) == "userdata" then
    return raw[1].bmp
  end
  for i = 0, 1 do if type(raw[i]) == "userdata" then return raw[i] end end
  for _, v in pairs(raw) do if type(v) == "userdata" then return v end end
  return nil
end

local function layout_nodes(nodes, cont_w, opts)
  opts = opts or {}
  local pad = opts.pad or PAD_X
  if not opts.keep_fonts then _font_reg = {} end
  local items, y = {}, (opts.start_y or 4)

  for idx, node in ipairs(nodes) do

    if node.tag == "font_def" then
      local data = fetch(node.url)
      if data and data ~= "" and type(data) == "userdata" then
        local h = node.height or (LINE_H - 2)
        _font_reg[node.id] = { data=data, line_h=h+2 }
      else
        _font_reg[node.id] = { data=_default_font, line_h=LINE_H }
      end

    elseif node.tag == "h1" then
      local ef = node.font or "__h1"
      local lh = _item_line_h(ef)
      if idx > 1 then y += 8 end
      _apply_font(ef)
      local x_start = calc_x_start(node.align, measure(node.text), cont_w, pad)
      _apply_font(nil)
      add(items, { tag="h1", text=node.text, y=y, font=ef, line_h=lh, x_start=x_start, color=node.color })
      y += lh + 4

    elseif node.tag == "h2" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 6 end
      _apply_font(node.font)
      local x_start = calc_x_start(node.align, measure(node.text), cont_w, pad)
      _apply_font(nil)
      add(items, { tag="h2", text=node.text, y=y, font=node.font, line_h=lh, x_start=x_start, color=node.color })
      y += lh + 3

    elseif node.tag == "h3" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 4 end
      _apply_font(node.font)
      local x_start = calc_x_start(node.align, measure(node.text), cont_w, pad)
      _apply_font(nil)
      add(items, { tag="h3", text=node.text, y=y, font=node.font, line_h=lh, x_start=x_start, color=node.color })
      y += lh + 2

    elseif node.tag == "p" then
      local lh = _item_line_h(node.font)
      _apply_font(node.font)
      if node.spans then
        for _, line_segs in ipairs(wrap_spans(node.spans, cont_w)) do
          local line_w = 0
          for _, seg in ipairs(line_segs) do line_w += measure(seg.text) end
          local x_start = calc_x_start(node.align, line_w, cont_w, pad)
          local lregs, rx = {}, x_start
          for _, seg in ipairs(line_segs) do
            local sw = measure(seg.text)
            if seg.link or seg.dl then
              local tw = measure((seg.text):match("^(.-)%s*$"))
              add(lregs, { x=rx, w=tw, link=seg.link, dl=seg.dl })
            end
            rx += sw
          end
          add(items, { tag="p", segs=line_segs, lregs=lregs, y=y, font=node.font, line_h=lh, x_start=x_start, color=node.color })
          y += lh
        end
      else
        for _, line in ipairs(wrap_text(node.text, cont_w)) do
          local x_start = calc_x_start(node.align, measure(line), cont_w, pad)
          add(items, { tag="p", text=line, y=y, font=node.font, line_h=lh, x_start=x_start, color=node.color })
          y += lh
        end
      end
      _apply_font(nil)
      y += 4

    elseif node.tag == "break" then
      add(items, { tag="break", y=y, line_h=node.height })
      y += node.height

    elseif node.tag == "download" then
      local lh     = LINE_H
      local text   = "download '" .. node.filename .. "'"
      local text_w = measure(text)
      local x_start = calc_x_start(node.align, text_w, cont_w, pad)
      y += 2
      add(items, { tag="download", text=text, url=node.url, filename=node.filename, y=y, line_h=lh, text_w=text_w, x_start=x_start, color=node.color, hover_color=node.hover_color })
      y += lh + 2

    elseif node.tag == "link" then
      local lh = _item_line_h(node.font)
      _apply_font(node.font)
      local text_w  = measure(node.text)
      local x_start = calc_x_start(node.align, text_w, cont_w, pad)
      _apply_font(nil)
      y += 2
      add(items, { tag="link", text=node.text, url=node.url, user=node.user, file=node.file, cart=node.cart, y=y, font=node.font, line_h=lh, text_w=text_w, x_start=x_start, color=node.color, hover_color=node.hover_color })
      y += lh + 2

    elseif node.tag == "code" then
      local mono_lh = MONO_LINE_H
      _apply_font("mono")
      local code_lines = {}
      for code_line in string.gmatch(node.text .. "\n", "([^\n]*)\n") do
        add(code_lines, code_line)
      end
      local block_h  = #code_lines * mono_lh + 6
      local copy_w   = measure("copy")
      _apply_font(nil)
      y += 2
      add(items, { tag="code", lines=code_lines, y=y, h=block_h, copy_str=node.text, line_h=mono_lh, copy_w=copy_w })
      y += block_h + 4

    elseif node.tag == "img" then
      local raw    = fetch(node.url)
      local sprite = extract_sprite(raw)
      if sprite then
        local iw, ih     = sprite:width(), sprite:height()
        local viewports  = node.viewports
        local first      = viewports[1] or {0, 0}
        local src_w      = node.cut_w or iw
        local src_h      = node.cut_h or ih
        local desired_w  = src_w * (node.img_scale or 1)
        local desired_h  = src_h * (node.img_scale or 1)
        local no_resize  = node.resize == "false"
        local dw, dh, scaled
        if no_resize then
          dw, dh, scaled = desired_w, desired_h, false
        else
          local scale = min(1, cont_w / desired_w)
          dw, dh = flr(desired_w * scale), flr(desired_h * scale)
          scaled = scale < 1
        end
        y += 4
        local animated = #viewports > 1
        add(items, { tag="img", sprite=sprite, y=y, h=dh, w=dw,
          src_x=first[1], src_y=first[2], src_w=src_w, src_h=src_h,
          viewports=animated and viewports or nil, anim_frames=node.anim_frames,
          align=node.align, scaled=scaled })
        y += dh + 4
      else
        add(items, { tag="p", text="image not found: " .. node.alt, y=y, line_h=LINE_H })
        y += LINE_H + 4
      end

    elseif node.tag == "comments" then
      local uid      = stat(64)
      local enabled  = uid and uid ~= 0
                    and current_url and string.match(current_url, "^podnet://")
      local text_w   = cont_w + PAD_X * 2 - CMT_AVAT - CMT_PAD * 3 - SCROLL_W
      local tname    = enabled and make_table_name(current_url) or nil
      local raw      = {}
      local laid, cy = {}, 0
      local scroll_area_h = node.height - CMT_HEAD_H - CMT_INPUT_H - 2

      local submit_flag = { requested = false }
      local cmt_gui = create_gui()
      local cmt_txt = cmt_gui:attach_text_editor {
        x = -500, y = -500, width = 300, height = 14,
        key_callback = {
          ["enter"] = function(self, k)
            submit_flag.requested = true
            return nil
          end
        },
        max_lines=1
      }

      y += 4
      add(items, {
        tag           = "comments",
        comments      = laid,
        content_h     = cy,
        raw_scores    = raw,
        table_name    = tname,
        text_w        = text_w,
        disabled      = not enabled,
        scroll_area_h = scroll_area_h,
        y             = y,
        h             = node.height,
        line_h        = node.height,
        scroll_y      = 0,
        max_scroll    = max(0, cy - scroll_area_h),
        gui           = cmt_gui,
        txt           = cmt_txt,
        submit_flag     = submit_flag,
        input_focused   = false,
        comments_ready  = false,
        poll_timer      = 0,
        btn_bg           = node.btn_bg,
        btn_bg_hover     = node.btn_bg_hover,
        btn_border       = node.btn_border,
        btn_border_hover = node.btn_border_hover,
        btn_text         = node.btn_text,
      })
      y += node.height + 4

    elseif node.tag == "webring" then
      local raw = fetch(node.ring_url)
      local title, join_url, urls = "webring", nil, {}
      if raw and type(raw) == "string" then
        local line_num = 0
        for ln in string.gmatch(raw .. "\n", "([^\n]*)\n") do
          local s = string.match(ln, "^%s*(.-)%s*$")
          if s ~= "" then
            line_num += 1
            if     line_num == 1 then title    = s
            elseif line_num == 2 then join_url = s
            else                      add(urls, s) end
          end
        end
      end
      local my_idx = nil
      for k, u in ipairs(urls) do
        if u == current_url then my_idx = k ; break end
      end
      if not my_idx and #urls > 0 then
        my_idx = flr(rnd(#urls)) + 1
      end
      local prev_url, next_url = nil, nil
      if my_idx and #urls > 1 then
        prev_url = urls[my_idx == 1 and #urls or my_idx - 1]
        next_url = urls[my_idx == #urls and 1 or my_idx + 1]
      end
      _apply_font(nil)
      local title_w  = measure(title)
      local join_w   = join_url and measure("join us") or 0
      local group_w  = join_url and (title_w + measure("  ") + join_w) or title_w
      local join_off = title_w + measure("  ")
      local item_h   = LINE_H + 4 + WEBRING_BTN_H + 4
      y += 4
      add(items, {
        tag           = "webring",
        title         = title,
        prev_url      = prev_url,
        next_url      = next_url,
        join_url      = join_url,
        group_w       = group_w,
        join_offset_x = join_off,
        join_w        = join_w,
        y             = y,
        h             = item_h,
        line_h        = item_h,
        btn_bg           = node.btn_bg,
        btn_bg_hover     = node.btn_bg_hover,
        btn_border       = node.btn_border,
        btn_border_hover = node.btn_border_hover,
        btn_text         = node.btn_text,
      })
      y += item_h + 4

    elseif node.tag == "audio" then
      y += 2
      add(items, { tag="audio", url=node.url, y=y, h=AUDIO_H, line_h=AUDIO_H, x_start=PAD_X })
      y += AUDIO_H + 4

    elseif node.tag == "grid" then
      local cols     = node.columns
      local num_cols = #cols
      local gap_x    = node.gap_x or node.gap or GRID_GAP
      local gap_y    = node.gap_y or node.gap or 0
      local total_fixed, auto_count = 0, 0
      for _, c in ipairs(cols) do
        if c == "auto" then auto_count += 1 else total_fixed += c end
      end
      local available = cont_w - gap_x * (num_cols - 1)
      local auto_w    = auto_count > 0 and max(20, flr((available - total_fixed) / auto_count)) or 0
      local col_widths, col_xs = {}, {}
      local cx = pad
      for _, c in ipairs(cols) do
        local w = (c == "auto") and auto_w or c
        add(col_widths, w)
        add(col_xs, cx)
        cx += w + gap_x
      end

      y += 4
      local ci = 1
      local first_row = true
      while ci <= #node.children do
        if not first_row then y += gap_y end
        first_row = false
        local row_start_y = y
        local row_max_h   = 0
        for col_idx = 1, num_cols do
          local child = node.children[ci + col_idx - 1]
          if child then
            local col_w      = col_widths[col_idx]
            local col_x      = col_xs[col_idx]
            local col_cont_w = col_w - GRID_PAD * 2
            local sub_items, sub_h = layout_nodes({child}, col_cont_w, { pad=GRID_PAD, start_y=0, keep_fonts=true })
            row_max_h = max(row_max_h, sub_h)
            for _, it in ipairs(sub_items) do
              local adj = {}
              for k, v in pairs(it) do adj[k] = v end
              adj.y         = row_start_y + it.y
              adj.x_off     = col_x
              adj.col_cont_w = col_cont_w
              adj.col_pad   = GRID_PAD
              add(items, adj)
            end
          end
        end
        y  = row_start_y + row_max_h
        ci += num_cols
      end
      y += 4
    end
  end

  local bottom = 0
  for _, item in ipairs(items) do
    bottom = max(bottom, item.y + (item.h or item.line_h or LINE_H))
  end
  return items, bottom + 2
end

-- hover helpers (use doc.ox/oy set by pdw_doc the previous frame)

local function link_hovered(doc, item)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  local lh = item.line_h or LINE_H
  local lx = (item.x_off or 0) + (item.x_start or PAD_X)
  return mx >= doc.ox + lx
     and mx <  doc.ox + lx + (item.text_w or measure(item.text))
     and my >= sy and my < sy + lh
end

local function copy_hovered(doc, item)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  local xoff = item.x_off or 0
  local cw   = item.col_cont_w or doc.cont_w
  local cp   = item.col_pad or PAD_X
  local lx   = doc.ox + xoff + cp + cw - (item.copy_w or measure("copy"))
  return mx >= lx and mx < lx + (item.copy_w or measure("copy"))
     and my >= sy + 2 and my < sy + 2 + (item.line_h or LINE_H)
end

local function seg_hovered(doc, item, seg_x, seg_w)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  local lh = item.line_h or LINE_H
  return mx >= doc.ox + seg_x and mx < doc.ox + seg_x + seg_w
     and my >= sy and my < sy + lh
end

local function inline_reg_hovered(doc, item)
  if not item.lregs or #item.lregs == 0 then return nil end
  local mx, my = mouse()
  local sy   = doc.oy + item.y - doc.scroll_y
  local lh   = item.line_h or LINE_H
  local xoff = item.x_off or 0
  if my < sy or my >= sy + lh then return nil end
  for _, reg in ipairs(item.lregs) do
    if mx >= doc.ox + xoff + reg.x and mx < doc.ox + xoff + reg.x + reg.w then
      return reg
    end
  end
  return nil
end

local function webring_btn_x(doc, item)
  local gw   = WEBRING_BTN_W * 2 + WEBRING_BTN_GAP
  local xoff = item.x_off or 0
  local cw   = item.col_cont_w or doc.cont_w
  local cp   = item.col_pad or PAD_X
  local lx   = doc.ox + xoff + cp + flr((cw - gw) / 2)
  return lx, lx + WEBRING_BTN_W + WEBRING_BTN_GAP
end

local function webring_btn_hovered(doc, item, which)
  local mx, my = mouse()
  local sy     = doc.oy + item.y - doc.scroll_y
  local by     = sy + LINE_H + 4
  local lx, rx = webring_btn_x(doc, item)
  local bx     = which == "prev" and lx or rx
  return mx >= bx and mx < bx + WEBRING_BTN_W
     and my >= by and my < by + WEBRING_BTN_H
end

local function webring_join_hovered(doc, item)
  if not item.join_url then return false end
  local mx, my = mouse()
  local sy   = doc.oy + item.y - doc.scroll_y
  if my < sy or my >= sy + LINE_H then return false end
  local xoff = item.x_off or 0
  local cw   = item.col_cont_w or doc.cont_w
  local cp   = item.col_pad or PAD_X
  local gx   = doc.ox + xoff + cp + flr((cw - item.group_w) / 2)
  local jx   = gx + item.join_offset_x
  return mx >= jx and mx < jx + item.join_w
end

local function comment_portrait_hovered(doc, item)
  if item.disabled or #item.comments == 0 then return nil end
  local mx, my = mouse()
  local iy  = doc.oy + item.y - doc.scroll_y
  local say = iy + CMT_HEAD_H + 1
  local sah = item.scroll_area_h
  if my < say or my >= say + sah then return nil end
  local ax1 = doc.ox + CMT_PAD
  local ax2 = ax1 + CMT_AVAT - 1
  if mx < ax1 or mx > ax2 then return nil end
  for _, c in ipairs(item.comments) do
    local icy = say + c.cy - item.scroll_y + CMT_VPAD
    if my >= icy and my < icy + CMT_AVAT then
      if c.user_id then
        return "podnet://" .. c.user_id .. "/index.podweb"
      end
      return nil
    end
  end
  return nil
end

local function draw_pill(x, y, w, h, col)
  local r = flr(h / 2)
  circfill(x + r,         y + r, r, col)
  circfill(x + w - 1 - r, y + r, r, col)
  rectfill(x + r, y, x + w - 1 - r, y + h - 1, col)
end

local function audio_btn_hovered(doc, item, btn)
  local mx, my = mouse()
  local iy = doc.oy + item.y - doc.scroll_y
  local ix = doc.ox + (item.x_off or 0) + (item.x_start or PAD_X)
  local by = iy + AUDIO_BTN_Y
  if btn == "rew" then
    return mx >= ix + AUDIO_REW_X  and mx < ix + AUDIO_REW_X  + 5 and my >= by and my < by + 5
  elseif btn == "play" then
    return mx >= ix + AUDIO_PLAY_X and mx < ix + AUDIO_PLAY_X + 4 and my >= by and my < by + 5
  elseif btn == "stop" then
    return mx >= ix + AUDIO_STOP_X and mx < ix + AUDIO_STOP_X + 4 and my >= by and my < by + 5
  end
  return false
end

local function audio_any_btn_hovered(doc, item)
  return audio_btn_hovered(doc, item, "rew")
      or audio_btn_hovered(doc, item, "play")
      or audio_btn_hovered(doc, item, "stop")
end

-- public API

function pdw_parse(src, width, height)
  local cont_w           = width - PAD_X * 2 - SCROLL_W
  local nodes, meta, theme = parse_podweb(src)
  local colors = {}
  for k, v in pairs(DEFAULT_COLORS) do colors[k] = v end
  for k, v in pairs(theme) do colors[k] = v end
  local items, content_h = layout_nodes(nodes, cont_w)
  local max_scroll       = max(0, content_h - height)
  local doc = {
    items          = items,
    meta           = meta,
    scroll_y       = 0,
    max_scroll     = max_scroll,
    width          = width,
    height         = height,
    cont_w         = cont_w,
    ox             = 0,
    oy             = 0,
    prev_mb        = 0,
    navigated_to   = nil,
    colors         = colors,
  }
  return doc, max_scroll
end

function pdw_update(doc)
  doc.navigated_to      = nil
  doc.copied            = false
  doc.download_requested = nil
  doc.hovered_url       = nil
  local mx, my, mb, _, mwy = mouse()
  -- auto-clear audio state when music ends naturally
  if _audio_playing ~= nil and stat(466) == -1 then
    _audio_playing   = nil
    _audio_play_time = 0
  end

  local cur_user = string.match(current_url, "podnet://(%d+)/")
  local function resolve_internal(lnk)
    if lnk.url then return lnk.url end
    if lnk.cart then return nil end
    local u = lnk.user or cur_user
    if u then return "podnet://" .. u .. "/" .. (lnk.file or "index.podweb") end
    return lnk.file
  end

  for _, item in ipairs(doc.items) do
    if (item.tag == "link" or item.tag == "download") and link_hovered(doc, item) then
      doc.hovered_url = resolve_internal(item)
      break
    end
    if item.tag == "p" then
      local reg = inline_reg_hovered(doc, item)
      if reg then
        if reg.dl then
          doc.hovered_url = reg.dl.url
        elseif reg.link then
          doc.hovered_url = resolve_internal(reg.link)
        end
        break
      end
    end
    if item.tag == "webring" then
      if item.prev_url and webring_btn_hovered(doc, item, "prev") then
        doc.hovered_url = item.prev_url
      elseif item.next_url and webring_btn_hovered(doc, item, "next") then
        doc.hovered_url = item.next_url
      elseif webring_join_hovered(doc, item) then
        doc.hovered_url = item.join_url
      end
      if doc.hovered_url then break end
    end
    if item.tag == "audio" and audio_any_btn_hovered(doc, item) then
      doc.hovered_url = item.url
      break
    end
    if item.tag == "comments" then
      local portrait_url = comment_portrait_hovered(doc, item)
      if portrait_url then
        doc.hovered_url = portrait_url
        break
      end
    end
  end

  if mwy and mwy ~= 0 then
    local scrolled = false
    if doc.oy then
      for _, item in ipairs(doc.items) do
        if item.tag == "comments" then
          local iy  = doc.oy + item.y - doc.scroll_y
          local say = iy + CMT_HEAD_H + 1
          if mx >= doc.ox and mx < doc.ox + doc.width
             and my >= say and my < say + item.scroll_area_h then
            item.scroll_y = mid(0, item.scroll_y - mwy * 8, item.max_scroll)
            scrolled = true
            break
          end
        end
      end
    end
    if not scrolled then
      doc.scroll_y = mid(0, doc.scroll_y - mwy * 8, doc.max_scroll)
    end
  end
  if btn(2) then doc.scroll_y = max(0,              doc.scroll_y - 3) end
  if btn(3) then doc.scroll_y = min(doc.max_scroll, doc.scroll_y + 3) end

  if (doc.prev_mb & 1) == 1 and (mb & 1) == 0 then
    for _, item in ipairs(doc.items) do
      if item.tag == "code" and copy_hovered(doc, item) then
        set_clipboard(item.copy_str)
        doc.copied = true
        break
      end
    end
    for _, item in ipairs(doc.items) do
      if item.tag == "download" and link_hovered(doc, item) then
        doc.download_requested = { url=item.url, filename=item.filename }
        break
      end
      if item.tag == "link" and link_hovered(doc, item) then
        if item.url then
          doc.navigated_to = { url=item.url }
        elseif item.cart then
          doc.navigated_to = { cart=item.cart }
        else
          doc.navigated_to = { user=item.user, file=item.file }
        end
        break
      end
      if item.tag == "p" then
        local reg = inline_reg_hovered(doc, item)
        if reg then
          if reg.dl then
            doc.download_requested = { url=reg.dl.url, filename=reg.dl.filename }
          elseif reg.link then
            local lnk = reg.link
            if lnk.url then
              doc.navigated_to = { url=lnk.url }
            elseif lnk.cart then
              doc.navigated_to = { cart=lnk.cart }
            else
              doc.navigated_to = { user=lnk.user, file=lnk.file }
            end
          end
          break
        end
      end
      if item.tag == "webring" then
        if item.prev_url and webring_btn_hovered(doc, item, "prev") then
          doc.navigated_to = { url=item.prev_url }
          break
        elseif item.next_url and webring_btn_hovered(doc, item, "next") then
          doc.navigated_to = { url=item.next_url }
          break
        elseif webring_join_hovered(doc, item) then
          doc.navigated_to = { url=item.join_url }
          break
        end
      end
      if item.tag == "audio" then
        local is_playing = _audio_playing == item.url and stat(466) ~= -1
        if audio_btn_hovered(doc, item, "play") then
          if is_playing then
            music(-1)
            _audio_playing   = nil
            _audio_play_time = 0
          else
            music(-1)
            local data = fetch(item.url)
            if data then
              data:poke(0x80000)
              music(0, nil, nil, 0x80000)
              _audio_playing   = item.url
              _audio_play_time = time()
              popup("playing: " .. item.url)
            end
          end
          break
        elseif audio_btn_hovered(doc, item, "stop") then
          if is_playing then
            music(-1)
            _audio_playing   = nil
            _audio_play_time = 0
          end
          break
        elseif audio_btn_hovered(doc, item, "rew") then
          music(-1)
          local data = fetch(item.url)
          if data then
            data:poke(0x80000)
            music(0, nil, nil, 0x80000)
            _audio_playing   = item.url
            _audio_play_time = time()
            popup("playing: " .. item.url)
          end
          break
        end
      end
      if item.tag == "comments" then
        local portrait_url = comment_portrait_hovered(doc, item)
        if portrait_url then
          doc.navigated_to = { url=portrait_url }
          break
        end
      end
    end
  end

  -- comment input: gui update, focus, and submit
  for _, item in ipairs(doc.items) do
    if item.tag == "comments" and item.gui then

      -- poll until scoresub returns data on first load
      if not item.comments_ready and item.table_name then
        item.poll_timer += 1
        if item.poll_timer % 30 == 1 then
          local raw = scoresub(item.table_name) or {}
          if #raw > 0 then
            item.raw_scores     = raw
            item.comments, item.content_h = layout_comment_entries(raw, item.text_w)
            item.max_scroll     = max(0, item.content_h - item.scroll_area_h)
            item.scroll_y       = item.max_scroll
            item.comments_ready = true
          end
        end
      end

      -- submit (enter key or post button)
      if not item.disabled and item.submit_flag and item.submit_flag.requested then
        item.submit_flag.requested = false
        local lines = item.txt:get_text()
        local text  = string.match((lines and lines[1]) or "", "^%s*(.-)%s*$")
        if text ~= "" and item.table_name then
          local uid = stat(64)
          local cur_score = 0
          for _, e in ipairs(item.raw_scores) do
            if tostring(e.user_id) == tostring(uid) then
              cur_score = e.score ; break
            end
          end
          local ts        = tostring(stat(86))
          local new_score = cur_score + 1
          scoresub(item.table_name, new_score, ts .. "|" .. text)
          -- optimistic patch: show comment immediately without waiting for server
          local patched, found = {}, false
          for _, e in ipairs(item.raw_scores) do
            if tostring(e.user_id) == tostring(uid) then
              local ec = {}
              for k, v in pairs(e) do ec[k] = v end
              ec.score = new_score
              ec.extra = ts .. "|" .. text
              add(patched, ec)
              found = true
            else
              add(patched, e)
            end
          end
          if not found then
            add(patched, { user_id=uid, username=stat(65) or "?", icon=stat(66), score=new_score, extra=ts .. "|" .. text })
          end
          item.raw_scores     = patched
          item.comments, item.content_h = layout_comment_entries(patched, item.text_w)
          item.max_scroll     = max(0, item.content_h - item.scroll_area_h)
          item.scroll_y       = item.max_scroll
          item.txt:set_text("")
          item.comments_ready = true
          popup("comment posted!", 3)
        end
      end

      item.gui:update_all()

      local focus_req = nil
      if (doc.prev_mb & 1) == 1 and (mb & 1) == 0 and doc.oy then
        local iy      = doc.oy + item.y - doc.scroll_y
        local ipy     = iy + item.h - CMT_INPUT_H
        local btn_w   = 24
        local cmt_w   = doc.width - SCROLL_W - 3
        local field_x = doc.ox + CMT_PAD
        local field_w = cmt_w - CMT_PAD * 3 - btn_w
        local field_y = ipy + 2
        local field_h = CMT_INPUT_H - 5
        local btn_x   = field_x + field_w + CMT_PAD
        local btn_x2  = doc.ox + cmt_w - CMT_PAD - 1

        if mx >= field_x and mx <= field_x + field_w and my >= field_y and my <= field_y + field_h then
          item.input_focused = true
          focus_req = true
        elseif mx >= btn_x and mx <= btn_x2 and my >= field_y and my <= field_y + field_h then
          item.submit_flag.requested = true
          item.input_focused = false
          focus_req = false
        else
          item.input_focused = false
          focus_req = false
        end
      end

      if focus_req ~= nil then
        item.txt:set_keyboard_focus(focus_req)
      end
    end
  end

  doc.prev_mb = mb
end

function pdw_load_comments(doc)
  for _, item in ipairs(doc.items) do
    if item.tag == "comments" and item.table_name then
      local raw           = scoresub(item.table_name) or {}
      item.raw_scores     = raw
      item.comments, item.content_h = layout_comment_entries(raw, item.text_w)
      item.max_scroll     = max(0, item.content_h - item.scroll_area_h)
      item.scroll_y       = item.max_scroll
    end
  end
end

function pdw_doc(doc, ox, oy)
  local C = doc.colors
  doc.ox, doc.oy = ox, oy
  clip(ox, oy, doc.width, doc.height)
  rectfill(ox, oy, ox + doc.width - 1, oy + doc.height - 1, C.bg)

  for _, item in ipairs(doc.items) do
    local y      = oy + item.y - doc.scroll_y
    local item_h = item.h or item.line_h or LINE_H
    local lh     = item.line_h or LINE_H
    if y + item_h > oy and y < oy + doc.height + lh then

      _apply_font(item.font)

      local eff_ox  = ox + (item.x_off or 0)
      local eff_cw  = item.col_cont_w or doc.cont_w
      local eff_pad = item.col_pad or PAD_X

      local col_clipped = item.x_off ~= nil
      if col_clipped then
        local cx1 = eff_ox
        local cy1 = max(y, oy)
        local cx2 = eff_ox + eff_cw + eff_pad * 2
        local cy2 = min(y + item_h, oy + doc.height)
        clip(cx1, cy1, cx2 - cx1, max(0, cy2 - cy1))
      end

      if item.tag == "h1" then
        print("\^u" .. item.text, eff_ox + (item.x_start or eff_pad), y, item.color or C.h1)

      elseif item.tag == "h2" then
        print("\^u" .. item.text, eff_ox + (item.x_start or eff_pad), y, item.color or C.h2)

      elseif item.tag == "h3" then
        print(item.text, eff_ox + (item.x_start or eff_pad), y, item.color or C.h3)

      elseif item.tag == "download" then
        local col = link_hovered(doc, item) and (item.hover_color or C.link_hover) or (item.color or C.link)
        local lx  = eff_ox + (item.x_start or eff_pad)
        print(item.text, lx, y, col)
        line(lx, y+lh-1, lx + item.text_w - 1, y+lh-1, col)

      elseif item.tag == "link" then
        local col = link_hovered(doc, item) and (item.hover_color or C.link_hover) or (item.color or C.link)
        local lx  = eff_ox + (item.x_start or eff_pad)
        print(item.text, lx, y, col)
        line(lx, y+lh-1, lx + item.text_w - 1, y+lh-1, col)

      elseif item.tag == "code" then
        _apply_font("mono")
        rectfill(eff_ox+eff_pad-2, y, eff_ox+eff_pad+eff_cw+2, y+item.h-1, 0)
        rect    (eff_ox+eff_pad-2, y, eff_ox+eff_pad+eff_cw+2, y+item.h-1, 5)
        local lx = eff_ox + eff_pad + eff_cw - item.copy_w
        print("copy", lx, y+3, copy_hovered(doc, item) and 7 or 5)
        for li, code_line in ipairs(item.lines) do
          print(code_line, eff_ox+eff_pad+2, y+3+(li-1)*lh, 11)
        end

      elseif item.tag == "img" then
        local align = item.scaled and "center" or (item.align or "center")
        local ix
        if align == "left" then
          ix = eff_ox + eff_pad
        elseif align == "right" then
          ix = eff_ox + eff_pad + eff_cw - item.w
        else
          ix = eff_ox + flr((eff_cw + eff_pad * 2 - item.w) / 2)
        end
        local sx, sy = item.src_x, item.src_y
        if item.viewports then
          local fi = flr(time() * 60 / item.anim_frames) % #item.viewports + 1
          local vp = item.viewports[fi]
          sx, sy = vp[1], vp[2]
        end
        sspr(item.sprite, sx, sy, item.src_w, item.src_h, ix, y, item.w, item.h)

      elseif item.tag == "webring" then
        _apply_font(nil)
        local gx = eff_ox + eff_pad + flr((eff_cw - item.group_w) / 2)
        print(item.title, gx, y, C.text)
        if item.join_url then
          local jx  = gx + item.join_offset_x
          local jcol = webring_join_hovered(doc, item) and C.link_hover or C.link
          print("join us", jx, y, jcol)
          line(jx, y+LINE_H-1, jx+item.join_w-1, y+LINE_H-1, jcol)
        end
        local by = y + LINE_H + 4
        local lx, rx = webring_btn_x(doc, item)
        local ph = webring_btn_hovered(doc, item, "prev")
        rectfill(lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and (item.btn_bg_hover or C.btn_bg_hover) or (item.btn_bg or C.btn_bg))
        rect    (lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and (item.btn_border_hover or C.btn_border_hover) or (item.btn_border or C.btn_border))
        local pw = measure("< prev")
        print("< prev", lx + flr((WEBRING_BTN_W - pw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, item.btn_text or C.btn_text)
        local nh = webring_btn_hovered(doc, item, "next")
        rectfill(rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and (item.btn_bg_hover or C.btn_bg_hover) or (item.btn_bg or C.btn_bg))
        rect    (rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and (item.btn_border_hover or C.btn_border_hover) or (item.btn_border or C.btn_border))
        local nw = measure("next >")
        print("next >", rx + flr((WEBRING_BTN_W - nw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, item.btn_text or C.btn_text)

      elseif item.tag == "audio" then
        _apply_font(nil)
        local ix         = eff_ox + (item.x_start or eff_pad)
        local is_playing = _audio_playing == item.url and stat(466) ~= -1
        -- pill background
        draw_pill(ix, y, AUDIO_W, AUDIO_H, C.text)
        -- progress bar track then fill
        local prog_x = ix + AUDIO_PROG_X
        local prog_y = y + 5
        local prog_h = 3
        rectfill(prog_x, prog_y, prog_x + AUDIO_PROG_W - 1, prog_y + prog_h - 1, C.bg)
        if is_playing then
          local elapsed = time() - _audio_play_time
          local fill_w  = flr(AUDIO_PROG_W * ((elapsed % 10) / 10))
          if fill_w > 0 then
            rectfill(prog_x, prog_y, prog_x + fill_w - 1, prog_y + prog_h - 1, C.link)
          end
        end
        -- buttons drawn as sub-sprites of sprite 7, white (color 7) → btn color
        local bby = y + AUDIO_BTN_Y
        -- rewind: sprite 7, sub-region (0,6) 5×5
        pal(7, audio_btn_hovered(doc, item, "rew") and C.btn_bg_hover or C.btn_bg)
        sspr(7, 0, 6, 5, 5, ix + AUDIO_REW_X, bby)
        pal()
        -- play / pause toggle: sprite 7, play=(0,0)4×5, pause=(4,0)4×5
        pal(7, audio_btn_hovered(doc, item, "play") and C.btn_bg_hover or C.btn_bg)
        if is_playing then
          sspr(7, 4, 0, 4, 5, ix + AUDIO_PLAY_X, bby)
        else
          sspr(7, 0, 0, 4, 5, ix + AUDIO_PLAY_X, bby)
        end
        pal()
        -- stop: sprite 7, sub-region (8,0) 4×5
        pal(7, audio_btn_hovered(doc, item, "stop") and C.btn_bg_hover or C.btn_bg)
        sspr(7, 8, 0, 4, 5, ix + AUDIO_STOP_X, bby)
        pal()

      elseif item.tag == "comments" then
        _apply_font(nil)
        local bx   = ox
        local bx2  = ox + doc.width - SCROLL_W - 3
        local say  = y + CMT_HEAD_H + 1
        local sah  = item.scroll_area_h
        local ipy  = y + item.h - CMT_INPUT_H

        -- header
        line(bx, y, bx2, y, C.text)
        print("Comments", bx + CMT_PAD, y + 2, C.text)
        line(bx, say - 1, bx2, say - 1, C.text)

        if item.disabled then
          local msg = "comments are only available on podnet:// pages when logged in"
          local mw  = print(msg, 0, -100)
          print(msg, bx + flr(((bx2 - bx) - mw) / 2), say + flr(item.scroll_area_h / 2) - 3, C.text)
          line(bx, y + item.h, bx2, y + item.h, C.text)
        else

        -- clip to scroll area and draw comments (intersected with document viewport)
        local cmt_cy1 = max(say, oy)
        local cmt_cy2 = min(say + sah, oy + doc.height)
        clip(bx, cmt_cy1, doc.width, max(0, cmt_cy2 - cmt_cy1))
        for _, c in ipairs(item.comments) do
          local cy = say + c.cy - item.scroll_y
          if cy + c.h > say and cy < say + sah then
            local icy = cy + CMT_VPAD
            if c.icon then
              spr(c.icon, bx + CMT_PAD, icy)
            else
              rectfill(bx + CMT_PAD, icy, bx + CMT_PAD + CMT_AVAT - 1, icy + CMT_AVAT - 1, 8)
            end
            local tx = bx + CMT_PAD + CMT_AVAT + CMT_PAD
            print(c.user, tx, icy, C.text)
            local dw = print(c.date, 0, -100)
            print(c.date, bx2 - SCROLL_W - CMT_PAD - dw, icy, C.text)
            for li, ln in ipairs(c.lines) do
              print(ln, tx, icy + li * LINE_H, C.text)
            end
          end
          local sep_y = say + c.cy + c.h - item.scroll_y
          if sep_y >= say and sep_y < say + sah then
            line(bx + CMT_PAD, sep_y, bx2 - SCROLL_W - CMT_PAD, sep_y, C.text)
          end
        end

        -- comment scrollbar
        if item.max_scroll > 0 then
          local sx      = bx2 - SCROLL_W + 1
          local thumb_h = max(6, flr(sah * sah / (sah + item.max_scroll)))
          local thumb_y = say + flr(item.scroll_y / item.max_scroll * (sah - thumb_h))
          line(sx, say, sx, say + sah - 1, 1)
          rectfill(sx, thumb_y, sx + SCROLL_W - 1, thumb_y + thumb_h - 1, 5)
        end

        -- restore doc clip
        clip(ox, oy, doc.width, doc.height)

        -- input row
        line(bx, ipy - 1, bx2, ipy - 1, C.text)
        local btn_w   = 24
        local field_x = bx + CMT_PAD
        local field_w = (bx2 - bx + 1) - CMT_PAD * 3 - btn_w
        local field_y = ipy + 2
        local field_h = CMT_INPUT_H - 5

        -- mock field with real text + cursor
        local border_col  = item.input_focused and (item.btn_border_hover or C.btn_border_hover) or (item.btn_border or C.btn_border)
        rect(field_x, field_y, field_x + field_w - 1, field_y + field_h - 1, border_col)
        if item.txt then
          local lines        = item.txt:get_text()
          local content      = (lines and lines[1]) or ""
          local cur_x        = item.txt:get_cursor()
          local before       = string.sub(content, 1, cur_x - 1)
          local cursor_px    = print(before, 0, -100)
          local inner_w      = field_w - CMT_PAD * 2
          local text_offset  = max(0, cursor_px - inner_w + 4)
          local fcy1 = max(field_y + 1, oy)
          local fcy2 = min(field_y + field_h - 1, oy + doc.height)
          clip(field_x + 1, fcy1, field_w - 2, max(0, fcy2 - fcy1))
          print(content, field_x + CMT_PAD - text_offset, field_y + 2, C.text)
          if item.input_focused and (popup_frame % 30) < 15 then
            local px = field_x + CMT_PAD + cursor_px - text_offset
            rectfill(px, field_y + 2, px + 2, field_y + field_h - 3, C.text)
          end
          clip(ox, oy, doc.width, doc.height)
        end

        local btn_x = field_x + field_w + CMT_PAD
        local mx, my = mouse()
        local post_hovered = mx >= btn_x and mx <= btn_x + btn_w - 1 and my >= field_y and my <= field_y + field_h - 1
        rectfill(btn_x, field_y, btn_x + btn_w - 1, field_y + field_h - 1, post_hovered and (item.btn_bg_hover or C.btn_bg_hover) or (item.btn_bg or C.btn_bg))
        rect    (btn_x, field_y, btn_x + btn_w - 1, field_y + field_h - 1, post_hovered and (item.btn_border_hover or C.btn_border_hover) or (item.btn_border or C.btn_border))
        local pw = print("post", 0, -100)
        print("post", btn_x + flr((btn_w - pw) / 2), field_y + 2, item.btn_text or C.btn_text)

        -- bottom border
        line(bx, y + item.h, bx2, y + item.h, C.text)
        end  -- disabled/enabled

      elseif item.tag == "p" and item.segs then
        local sx = (item.x_off or 0) + (item.x_start or PAD_X)
        for _, seg in ipairs(item.segs) do
          local sw = measure(seg.text)
          if seg.link or seg.dl then
            local tw = measure((seg.text):match("^(.-)%s*$"))
            local lnk = seg.link or seg.dl
            local col = seg_hovered(doc, item, sx, tw) and (lnk.hover_color or C.link_hover) or (lnk.color or C.link)
            print(seg.text, ox + sx, y, col)
            line(ox + sx, y+lh-1, ox + sx + tw - 1, y+lh-1, col)
          else
            print(seg.text, ox + sx, y, item.color or C.text)
          end
          sx += sw
        end

      elseif item.text then
        print(item.text, eff_ox + (item.x_start or eff_pad), y, item.color or C.text)
      end

      _apply_font(nil)
      if col_clipped then clip(ox, oy, doc.width, doc.height) end
    end
  end

  -- scrollbar
  if doc.max_scroll > 0 then
    local sx      = ox + doc.width - SCROLL_W
    local thumb_h = max(8, flr(doc.height * doc.height / (doc.height + doc.max_scroll)))
    local thumb_y = oy + flr(doc.scroll_y / doc.max_scroll * (doc.height - thumb_h))
    rectfill(sx, oy,      sx+SCROLL_W-1, oy+doc.height-1, 1)
    rectfill(sx, thumb_y, sx+SCROLL_W-1, thumb_y+thumb_h-1, 5)
  end

  clip()
end
