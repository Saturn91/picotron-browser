--[[pod_format="raw",created="2026-04-17 08:26:09",modified="2026-04-22 18:28:42",revision=29,xstickers={}]]
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
        local key, val = string.match(lines[i], "^(%w+)=(%d+)$")
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
      if url then add(nodes, { tag="img", url=url, alt=alt or url, align=align, resize=resize }) end
      i += 1

    elseif string.match(l, "^%[break") then
      local h = tonumber(string.match(l, "height=(%d+)")) or LINE_H
      add(nodes, { tag="break", height=h })
      i += 1

    elseif string.match(l, "^%[comments") then
      local h = tonumber(string.match(l, "height=(%d+)")) or 140
      add(nodes, { tag="comments", height=h })
      i += 1

    elseif string.match(l, "^%[webring ") then
      local my_url   = string.match(l, "my%-url=([^,%s%]]+)")
      local ring_url = string.match(l, "ring%-data=([^%s%]]+)")
      if my_url and ring_url then
        add(nodes, { tag="webring", my_url=my_url, ring_url=ring_url })
      end
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

local function calc_x_start(align, text_w, cont_w)
  if align == "center" then return PAD_X + flr((cont_w - text_w) / 2)
  elseif align == "right" then return PAD_X + cont_w - text_w
  else return PAD_X end
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

local function layout_nodes(nodes, cont_w)
  _font_reg = {}
  local items, y = {}, 4

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
      local x_start = calc_x_start(node.align, measure(node.text), cont_w)
      _apply_font(nil)
      add(items, { tag="h1", text=node.text, y=y, font=ef, line_h=lh, x_start=x_start, color=node.color })
      y += lh + 4

    elseif node.tag == "h2" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 6 end
      _apply_font(node.font)
      local x_start = calc_x_start(node.align, measure(node.text), cont_w)
      _apply_font(nil)
      add(items, { tag="h2", text=node.text, y=y, font=node.font, line_h=lh, x_start=x_start, color=node.color })
      y += lh + 3

    elseif node.tag == "h3" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 4 end
      _apply_font(node.font)
      local x_start = calc_x_start(node.align, measure(node.text), cont_w)
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
          local x_start = calc_x_start(node.align, line_w, cont_w)
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
          local x_start = calc_x_start(node.align, measure(line), cont_w)
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
      local x_start = calc_x_start(node.align, text_w, cont_w)
      y += 2
      add(items, { tag="download", text=text, url=node.url, filename=node.filename, y=y, line_h=lh, text_w=text_w, x_start=x_start, color=node.color, hover_color=node.hover_color })
      y += lh + 2

    elseif node.tag == "link" then
      local lh = _item_line_h(node.font)
      _apply_font(node.font)
      local text_w  = measure(node.text)
      local x_start = calc_x_start(node.align, text_w, cont_w)
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
        local no_resize  = node.resize == "false"
        local dw, dh, scaled
        if no_resize then
          dw, dh, scaled = iw, ih, false
        else
          local scale = min(1, cont_w / iw)
          dw, dh = flr(iw * scale), flr(ih * scale)
          scaled = scale < 1
        end
        y += 4
        add(items, { tag="img", sprite=sprite, y=y, h=dh, w=dw, src_w=iw, src_h=ih, align=node.align, scaled=scaled })
        y += dh + 4
      else
        add(items, { tag="p", text="image not found: " .. node.alt, y=y, line_h=LINE_H })
        y += LINE_H + 4
      end

    elseif node.tag == "comments" then
      local mock = {
        { user="cornet",       date="2026-04-20", text="Great browser! Works really well on my setup. Keep it up!" },
        { user="zep",          date="2026-04-21", text="Loving the webring feature, very creative idea :)" },
        { user="saturn91",     date="2026-04-22", text="Thanks everyone for the kind words!" },
        { user="pancelor",     date="2026-04-23", text="Custom fonts are a nice touch, makes each page feel unique." },
        { user="morningtoast", date="2026-04-24", text="Just found this browser, amazing what you can do in Picotron!" },
      }
      local text_w = cont_w + PAD_X * 2 - CMT_AVAT - CMT_PAD * 3 - SCROLL_W
      _apply_font(nil)
      local laid, cy = {}, 0
      for _, c in ipairs(mock) do
        local wrapped = wrap_text(c.text, text_w)
        local h = CMT_VPAD + max(CMT_AVAT, LINE_H + #wrapped * LINE_H) + CMT_VPAD
        add(laid, { user=c.user, date=c.date, lines=wrapped, cy=cy, h=h })
        cy += h + 1
      end
      local scroll_area_h = node.height - CMT_HEAD_H - CMT_INPUT_H - 2

      local cmt_gui = create_gui()
      local cmt_txt
      cmt_txt = cmt_gui:attach_text_editor {
        x = -500, y = -500, width = 300, height = 14,
        key_callback = {
          ["enter"] = function(self, k)
            local lines = self:get_text()
            local text  = (lines and lines[1]) or ""
            if text ~= "" then popup("comment: " .. text, 3) end
            self:set_text("")
            return nil
          end
        }
      }

      y += 4
      add(items, {
        tag           = "comments",
        comments      = laid,
        content_h     = cy,
        scroll_area_h = scroll_area_h,
        y             = y,
        h             = node.height,
        line_h        = node.height,
        scroll_y      = 0,
        max_scroll    = max(0, cy - scroll_area_h),
        gui           = cmt_gui,
        txt           = cmt_txt,
        input_focused = false,
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
        if u == node.my_url then my_idx = k ; break end
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
      })
      y += item_h + 4
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
  local lx = item.x_start or PAD_X
  return mx >= doc.ox + lx
     and mx <  doc.ox + lx + (item.text_w or measure(item.text))
     and my >= sy and my < sy + lh
end

local function copy_hovered(doc, item)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  local lx = doc.ox + PAD_X + doc.cont_w - (item.copy_w or measure("copy"))
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
  local sy = doc.oy + item.y - doc.scroll_y
  local lh = item.line_h or LINE_H
  if my < sy or my >= sy + lh then return nil end
  for _, reg in ipairs(item.lregs) do
    if mx >= doc.ox + reg.x and mx < doc.ox + reg.x + reg.w then
      return reg
    end
  end
  return nil
end

local function webring_btn_x(doc, item)
  local gw = WEBRING_BTN_W * 2 + WEBRING_BTN_GAP
  local lx = doc.ox + PAD_X + flr((doc.cont_w - gw) / 2)
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
  local sy = doc.oy + item.y - doc.scroll_y
  if my < sy or my >= sy + LINE_H then return false end
  local gx = doc.ox + PAD_X + flr((doc.cont_w - item.group_w) / 2)
  local jx = gx + item.join_offset_x
  return mx >= jx and mx < jx + item.join_w
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
  local mx, my, mb, _, mwy = mouse()

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
    end
  end

  -- comment input: gui update, focus, and submit
  for _, item in ipairs(doc.items) do
    if item.tag == "comments" and item.gui then
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
          local lines = item.txt:get_text()
          local text  = (lines and lines[1]) or ""
          if text ~= "" then popup("comment: " .. text, 3) end
          item.txt:set_text("")
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

      if item.tag == "h1" then
        print("\^u" .. item.text, ox + (item.x_start or PAD_X), y, item.color or C.h1)

      elseif item.tag == "h2" then
        print("\^u" .. item.text, ox + (item.x_start or PAD_X), y, item.color or C.h2)

      elseif item.tag == "h3" then
        print(item.text, ox + (item.x_start or PAD_X), y, item.color or C.h3)

      elseif item.tag == "download" then
        local col = link_hovered(doc, item) and (item.hover_color or C.link_hover) or (item.color or C.link)
        local lx  = ox + (item.x_start or PAD_X)
        print(item.text, lx, y, col)
        line(lx, y+lh-1, lx + item.text_w - 1, y+lh-1, col)

      elseif item.tag == "link" then
        local col = link_hovered(doc, item) and (item.hover_color or C.link_hover) or (item.color or C.link)
        local lx  = ox + (item.x_start or PAD_X)
        print(item.text, lx, y, col)
        line(lx, y+lh-1, lx + item.text_w - 1, y+lh-1, col)

      elseif item.tag == "code" then
        _apply_font("mono")
        rectfill(ox+PAD_X-2, y, ox+PAD_X+doc.cont_w+2, y+item.h-1, 0)
        rect    (ox+PAD_X-2, y, ox+PAD_X+doc.cont_w+2, y+item.h-1, 5)
        local lx = ox + PAD_X + doc.cont_w - item.copy_w
        print("copy", lx, y+3, copy_hovered(doc, item) and 7 or 5)
        for li, code_line in ipairs(item.lines) do
          print(code_line, ox+PAD_X+2, y+3+(li-1)*lh, 11)
        end

      elseif item.tag == "img" then
        local align = item.scaled and "center" or (item.align or "center")
        local ix
        if align == "left" then
          ix = ox + PAD_X
        elseif align == "right" then
          ix = ox + PAD_X + doc.cont_w - item.w
        else
          ix = ox + flr((doc.width - item.w) / 2)
        end
        if item.src_w == item.w and item.src_h == item.h then
          spr(item.sprite, ix, y)
        else
          sspr(item.sprite, 0, 0, item.src_w, item.src_h, ix, y, item.w, item.h)
        end

      elseif item.tag == "webring" then
        _apply_font(nil)
        local gx = ox + PAD_X + flr((doc.cont_w - item.group_w) / 2)
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
        rectfill(lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and C.btn_bg_hover or C.btn_bg)
        rect    (lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and C.btn_border_hover or C.btn_border)
        local pw = measure("< prev")
        print("< prev", lx + flr((WEBRING_BTN_W - pw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, C.btn_text)
        local nh = webring_btn_hovered(doc, item, "next")
        rectfill(rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and C.btn_bg_hover or C.btn_bg)
        rect    (rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and C.btn_border_hover or C.btn_border)
        local nw = measure("next >")
        print("next >", rx + flr((WEBRING_BTN_W - nw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, C.btn_text)

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

        -- clip to scroll area and draw comments
        clip(bx, say, doc.width, sah)
        for _, c in ipairs(item.comments) do
          local cy = say + c.cy - item.scroll_y
          if cy + c.h > say and cy < say + sah then
            local icy = cy + CMT_VPAD
            rectfill(bx + CMT_PAD, icy, bx + CMT_PAD + CMT_AVAT - 1, icy + CMT_AVAT - 1, 8)
            local tx = bx + CMT_PAD + CMT_AVAT + CMT_PAD
            print(c.user, tx, icy, C.text)
            local dw = print(c.date, 0, -100)
            print(c.date, bx2 - SCROLL_W - CMT_PAD - dw, icy, 5)
            for li, ln in ipairs(c.lines) do
              print(ln, tx, icy + li * LINE_H, C.text)
            end
          end
          local sep_y = say + c.cy + c.h - item.scroll_y
          if sep_y >= say and sep_y < say + sah then
            line(bx + CMT_PAD, sep_y, bx2 - SCROLL_W - CMT_PAD, sep_y, 5)
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
        local border_col  = item.input_focused and 6 or 5
        rect(field_x, field_y, field_x + field_w - 1, field_y + field_h - 1, border_col)
        if item.txt then
          local lines        = item.txt:get_text()
          local content      = (lines and lines[1]) or ""
          local cur_x        = item.txt:get_cursor()
          local before       = string.sub(content, 1, cur_x - 1)
          local cursor_px    = print(before, 0, -100)
          local inner_w      = field_w - CMT_PAD * 2
          local text_offset  = max(0, cursor_px - inner_w + 4)
          clip(field_x + 1, field_y + 1, field_w - 2, field_h - 2)
          print(content, field_x + CMT_PAD - text_offset, field_y + 2, C.text)
          if item.input_focused and (popup_frame % 30) < 15 then
            local px = field_x + CMT_PAD + cursor_px - text_offset
            rectfill(px, field_y + 2, px + 2, field_y + field_h - 3, C.text)
          end
          clip(ox, oy, doc.width, doc.height)
        end

        local btn_x = field_x + field_w + CMT_PAD
        rectfill(btn_x, field_y, btn_x + btn_w - 1, field_y + field_h - 1, 2)
        rect    (btn_x, field_y, btn_x + btn_w - 1, field_y + field_h - 1, 5)
        local pw = print("post", 0, -100)
        print("post", btn_x + flr((btn_w - pw) / 2), field_y + 2, C.text)

        -- bottom border
        line(bx, y + item.h, bx2, y + item.h, C.text)

      elseif item.tag == "p" and item.segs then
        local sx = item.x_start or PAD_X
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
        print(item.text, ox + (item.x_start or PAD_X), y, item.color or C.text)
      end

      _apply_font(nil)
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
