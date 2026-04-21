--[[pod_format="raw",created="2026-04-17 08:26:09",modified="2026-04-20 21:08:15",revision=28,xstickers={}]]
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
      local url      = string.match(attrs, 'url="([^"]+)"') or string.match(attrs, "url=([^%s%]\"]+)")
      local filename = url and (string.match(url, "/([^/]+)$") or url) or "file"
      add(spans, { type="download", text="download '" .. filename .. "'", url=url, filename=filename })
    else
      local url  = string.match(attrs, 'url="([^"]+)"') or string.match(attrs, "url=([^%s%]\"]+)")
      local user = not url and string.match(attrs, "user=(%d+)")
      local file = not url and attrs and string.match(attrs, "file=(%S+)")
      local cart = not url and attrs and string.match(attrs, "cart=#?([^%s%]]+)")
      add(spans, { type="link", text=inner, url=url, user=user, file=file, cart=cart })
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
  return { font = string.match(s, "font=([%w_%-]+)") }
end

local function parse_podweb(src)
  local nodes, lines, meta = {}, {}, {}
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
        add(nodes, { tag=tag, spans=parse_inline(text), font=attrs.font })
      else
        add(nodes, { tag=tag, text=text, font=attrs.font })
      end
      i += 1

    elseif string.match(l, "^%[img") then
      local url = string.match(l, "url=([^%s%]]+)")
      local alt = string.match(l, "alt=([^%]]+)")
      if alt then alt = string.match(alt, "^%s*(.-)%s*$") end
      if url then add(nodes, { tag="img", url=url, alt=alt or url }) end
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
        local filename = string.match(url, "/([^/]+)$") or url
        add(nodes, { tag="download", url=url, filename=filename })
      end
      i += 1

    elseif string.match(l, "^%[link") then
      local attrs = string.match(l, "^%[link([^%]]*)%]")
      local text  = string.match(l, "^%[link[^%]]*%] (.+)")
      if text then
        local url  = attrs and (string.match(attrs, 'url="([^"]+)"') or string.match(attrs, 'url=([^%s%]"]+)'))
        local cart = not url and attrs and string.match(attrs, "cart=#?([^%s%]]+)")
        local font = attrs and string.match(attrs, "font=([%w_%-]+)")
        add(nodes, {
          tag  = "link",
          text = text,
          url  = url,
          user = not url and not cart and attrs and string.match(attrs, "user=(%d+)"),
          file = not url and not cart and attrs and string.match(attrs, "file=(%S+)"),
          cart = cart,
          font = font,
        })
      end
      i += 1

    elseif string.match(l, "^%[[%a%d]+[^%]]*%] .+") then
      local tag_part = string.match(l, "^%[([^%]]+)%]")
      local tag      = string.lower(string.match(tag_part, "^([%a%d]+)"))
      local text     = string.match(l, "^%[[^%]]+%] (.+)")
      local attrs    = parse_attrs(tag_part)
      if tag == "p" and (string.find(text, "%[link%-") or string.find(text, "%[download ")) then
        add(nodes, { tag=tag, spans=parse_inline(text), font=attrs.font })
      else
        add(nodes, { tag=tag, text=text, font=attrs.font })
      end
      i += 1

    else
      i += 1
    end
  end

  return nodes, meta
end

-- layout

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
      add(items, { tag="h1", text=node.text, y=y, font=ef, line_h=lh })
      y += lh + 4

    elseif node.tag == "h2" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 6 end
      add(items, { tag="h2", text=node.text, y=y, font=node.font, line_h=lh })
      y += lh + 3

    elseif node.tag == "h3" then
      local lh = _item_line_h(node.font)
      if idx > 1 then y += 4 end
      add(items, { tag="h3", text=node.text, y=y, font=node.font, line_h=lh })
      y += lh + 2

    elseif node.tag == "p" then
      local lh = _item_line_h(node.font)
      _apply_font(node.font)
      if node.spans then
        for _, line_segs in ipairs(wrap_spans(node.spans, cont_w)) do
          local lregs, rx = {}, PAD_X
          for _, seg in ipairs(line_segs) do
            local sw = measure(seg.text)
            if seg.link or seg.dl then
              local tw = measure((seg.text):match("^(.-)%s*$"))
              add(lregs, { x=rx, w=tw, link=seg.link, dl=seg.dl })
            end
            rx += sw
          end
          add(items, { tag="p", segs=line_segs, lregs=lregs, y=y, font=node.font, line_h=lh })
          y += lh
        end
      else
        for _, line in ipairs(wrap_text(node.text, cont_w)) do
          add(items, { tag="p", text=line, y=y, font=node.font, line_h=lh })
          y += lh
        end
      end
      _apply_font(nil)
      y += 4

    elseif node.tag == "download" then
      local lh   = LINE_H
      local text = "download '" .. node.filename .. "'"
      local text_w = measure(text)
      y += 2
      add(items, { tag="download", text=text, url=node.url, filename=node.filename, y=y, line_h=lh, text_w=text_w })
      y += lh + 2

    elseif node.tag == "link" then
      local lh = _item_line_h(node.font)
      _apply_font(node.font)
      local text_w = measure(node.text)
      _apply_font(nil)
      y += 2
      add(items, { tag="link", text=node.text, url=node.url, user=node.user, file=node.file, cart=node.cart, y=y, font=node.font, line_h=lh, text_w=text_w })
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
        local iw, ih = sprite:width(), sprite:height()
        local scale  = min(1, cont_w / iw)
        local dw, dh = flr(iw * scale), flr(ih * scale)
        y += 4
        add(items, { tag="img", sprite=sprite, y=y, h=dh, w=dw, src_w=iw, src_h=ih })
        y += dh + 4
      else
        add(items, { tag="p", text="image not found: " .. node.alt, y=y, line_h=LINE_H })
        y += LINE_H + 4
      end

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
  return mx >= doc.ox + PAD_X
     and mx <  doc.ox + PAD_X + (item.text_w or measure(item.text))
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
  local nodes, meta      = parse_podweb(src)
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
  }
  return doc, max_scroll
end

function pdw_update(doc)
  doc.navigated_to      = nil
  doc.copied            = false
  doc.download_requested = nil
  local _, _, mb, _, mwy = mouse()

  if mwy and mwy ~= 0 then
    doc.scroll_y = mid(0, doc.scroll_y - mwy * 8, doc.max_scroll)
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

  doc.prev_mb = mb
end

function pdw_doc(doc, ox, oy)
  doc.ox, doc.oy = ox, oy
  clip(ox, oy, doc.width, doc.height)

  for _, item in ipairs(doc.items) do
    local y      = oy + item.y - doc.scroll_y
    local item_h = item.h or item.line_h or LINE_H
    local lh     = item.line_h or LINE_H
    if y + item_h > oy and y < oy + doc.height + lh then

      _apply_font(item.font)

      if item.tag == "h1" then
        print("\^u" .. item.text, ox + PAD_X, y, 7)

      elseif item.tag == "h2" then
        print("\^u" .. item.text, ox + PAD_X, y, 12)

      elseif item.tag == "h3" then
        print(item.text, ox + PAD_X, y, 12)

      elseif item.tag == "download" then
        local col = link_hovered(doc, item) and 29 or 30
        print(item.text, ox + PAD_X, y, col)
        line(ox + PAD_X, y+lh-1, ox + PAD_X + item.text_w - 1, y+lh-1, col)

      elseif item.tag == "link" then
        local col = link_hovered(doc, item) and 29 or 30
        print(item.text, ox + PAD_X, y, col)
        line(ox + PAD_X, y+lh-1, ox + PAD_X + item.text_w - 1, y+lh-1, col)

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
        local ix = ox + flr((doc.width - item.w) / 2)
        if item.src_w == item.w and item.src_h == item.h then
          spr(item.sprite, ix, y)
        else
          sspr(item.sprite, 0, 0, item.src_w, item.src_h, ix, y, item.w, item.h)
        end

      elseif item.tag == "webring" then
        _apply_font(nil)
        local gx = ox + PAD_X + flr((doc.cont_w - item.group_w) / 2)
        print(item.title, gx, y, 6)
        if item.join_url then
          local jx  = gx + item.join_offset_x
          local jcol = webring_join_hovered(doc, item) and 29 or 30
          print("join us", jx, y, jcol)
          line(jx, y+LINE_H-1, jx+item.join_w-1, y+LINE_H-1, jcol)
        end
        local by = y + LINE_H + 4
        local lx, rx = webring_btn_x(doc, item)
        local ph = webring_btn_hovered(doc, item, "prev")
        rectfill(lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and 5 or 1)
        rect    (lx, by, lx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, ph and 12 or 5)
        local pw = measure("< prev")
        print("< prev", lx + flr((WEBRING_BTN_W - pw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, 7)
        local nh = webring_btn_hovered(doc, item, "next")
        rectfill(rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and 5 or 1)
        rect    (rx, by, rx+WEBRING_BTN_W-1, by+WEBRING_BTN_H-1, nh and 12 or 5)
        local nw = measure("next >")
        print("next >", rx + flr((WEBRING_BTN_W - nw) / 2), by + flr((WEBRING_BTN_H - LINE_H) / 2) + 1, 7)

      elseif item.tag == "p" and item.segs then
        local sx = PAD_X
        for _, seg in ipairs(item.segs) do
          local sw = measure(seg.text)
          if seg.link or seg.dl then
            local tw = measure((seg.text):match("^(.-)%s*$"))
            local col = seg_hovered(doc, item, sx, tw) and 29 or 30
            print(seg.text, ox + sx, y, col)
            line(ox + sx, y+lh-1, ox + sx + tw - 1, y+lh-1, col)
          else
            print(seg.text, ox + sx, y, 6)
          end
          sx += sw
        end

      else
        print(item.text, ox + PAD_X, y, 6)
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
