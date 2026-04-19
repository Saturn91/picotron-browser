--[[pod_format="raw",created="2026-04-17 08:26:09",modified="2026-04-17 22:31:44",revision=7]]
-- podweb-markdown.lua
-- API: pdw_parse(src, width, height) -> document, max_scroll
--      pdw_update(document)          -> handles scrolling, links, copy
--      pdw_doc(document, x, y)       -> renders document with scrollbar
--
-- After pdw_update, check document.navigated_to = {user, file} for link clicks.
-- It is reset automatically at the start of the next pdw_update call.

local LINE_H   = 10
local CHAR_W   = 4
local PAD_X    = 6
local SCROLL_W = 4

-- -- text helpers --------------------------------------------------------------

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
    local ls, le, attrs, inner = string.find(text, "%[link%-([^%]]*)%](.-)%[%-link%]", pos)
    if not ls then
      local tail = string.sub(text, pos)
      if tail ~= "" then add(spans, { type="text", text=tail }) end
      break
    end
    if ls > pos then add(spans, { type="text", text=string.sub(text, pos, ls-1) }) end
    local url  = string.match(attrs, 'url="([^"]+)"') or string.match(attrs, "url=([^%s%]\"]+)")
    local user = not url and string.match(attrs, "user=(%d+)")
    local file = not url and attrs and string.match(attrs, "file=(%S+)")
    add(spans, { type="link", text=inner, url=url, user=user, file=file })
    pos = le + 1
  end
  return spans
end

local function wrap_spans(spans, max_w)
  local toks = {}
  for _, span in ipairs(spans) do
    local lnk = span.type == "link" and span or nil
    for word in string.gmatch(span.text, "%S+") do
      add(toks, { text=word, link=lnk })
    end
  end
  if #toks == 0 then return {{}} end
  local lines, cur, cur_w = {}, {}, 0
  local function push(text, link)
    local last = cur[#cur]
    if last and last.link == link then last.text ..= text
    else add(cur, { text=text, link=link }) end
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
    push(tok.text, tok.link)
    cur_w += sw + tw
  end
  if #cur > 0 then add(lines, cur) end
  if #lines == 0 then add(lines, {}) end
  return lines
end

-- -- parser --------------------------------------------------------------------

local function parse_podweb(src)
  local nodes, lines, meta = {}, {}, {}
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

    elseif string.match(l, "^%[[%a%d]+%-%]") then
      local tag   = string.lower(string.match(l, "^%[([%a%d]+)%-%]"))
      local close = "[-" .. tag .. "]"
      local parts = {}
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
      if tag == "p" and string.find(text, "%[link%-") then
        add(nodes, { tag=tag, spans=parse_inline(text) })
      else
        add(nodes, { tag=tag, text=text })
      end
      i += 1

    elseif string.match(l, "^%[img") then
      local url = string.match(l, "url=([^%s%]]+)")
      local alt = string.match(l, "alt=([^%]]+)")
      if alt then alt = string.match(alt, "^%s*(.-)%s*$") end
      if url then add(nodes, { tag="img", url=url, alt=alt or url }) end
      i += 1

    elseif string.match(l, "^%[link") then
      local attrs = string.match(l, "^%[link([^%]]*)%]")
      local text  = string.match(l, "^%[link[^%]]*%] (.+)")
      if text then
        local url = attrs and (string.match(attrs, 'url="([^"]+)"') or string.match(attrs, 'url=([^%s%]"]+)'))
        add(nodes, {
          tag  = "link",
          text = text,
          url  = url,
          user = not url and attrs and string.match(attrs, "user=(%d+)"),
          file = not url and attrs and string.match(attrs, "file=(%S+)"),
        })
      end
      i += 1

    elseif string.match(l, "^%[[%a%d]+%] .+") then
      local tag  = string.lower(string.match(l, "^%[([%a%d]+)%]"))
      local text = string.match(l, "^%[[%a%d]+%] (.+)")
      if tag == "p" and string.find(text, "%[link%-") then
        add(nodes, { tag=tag, spans=parse_inline(text) })
      else
        add(nodes, { tag=tag, text=text })
      end
      i += 1

    else
      i += 1
    end
  end

  return nodes, meta
end

-- -- layout --------------------------------------------------------------------

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
  local items, y = {}, 4

  for idx, node in ipairs(nodes) do
    if node.tag == "h1" then
      if idx > 1 then y += 8 end
      add(items, { tag="h1", text=node.text, y=y })
      y += LINE_H + 4

    elseif node.tag == "h2" then
      if idx > 1 then y += 6 end
      add(items, { tag="h2", text=node.text, y=y })
      y += LINE_H + 3

    elseif node.tag == "p" then
      if node.spans then
        for _, line_segs in ipairs(wrap_spans(node.spans, cont_w)) do
          local lregs, rx = {}, PAD_X
          for _, seg in ipairs(line_segs) do
            local sw = measure(seg.text)
            if seg.link then
              local tw = measure((seg.text):match("^(.-)%s*$"))
              add(lregs, { x=rx, w=tw, link=seg.link })
            end
            rx += sw
          end
          add(items, { tag="p", segs=line_segs, lregs=lregs, y=y })
          y += LINE_H
        end
      else
        for _, line in ipairs(wrap_text(node.text, cont_w)) do
          add(items, { tag="p", text=line, y=y })
          y += LINE_H
        end
      end
      y += 4

    elseif node.tag == "link" then
      y += 2
      add(items, { tag="link", text=node.text, url=node.url, user=node.user, file=node.file, y=y })
      y += LINE_H + 2

    elseif node.tag == "code" then
      local code_lines = {}
      for code_line in string.gmatch(node.text .. "\n", "([^\n]*)\n") do
        add(code_lines, code_line)
      end
      local block_h = #code_lines * LINE_H + 6
      y += 2
      add(items, { tag="code", lines=code_lines, y=y, h=block_h, copy_str=node.text })
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
        add(items, { tag="p", text="image not found: " .. node.alt, y=y })
        y += LINE_H + 4
      end
    end
  end

  local bottom = 0
  for _, item in ipairs(items) do
    bottom = max(bottom, item.y + (item.h or LINE_H))
  end
  return items, bottom + 32
end

-- -- hover helpers (use doc.ox/oy set by pdw_doc the previous frame) -----------

local function link_hovered(doc, item)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  return mx >= doc.ox + PAD_X
     and mx <  doc.ox + PAD_X + measure(item.text)
     and my >= sy and my < sy + LINE_H
end

local function copy_hovered(doc, item)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  local lw = measure("copy")
  local lx = doc.ox + PAD_X + doc.cont_w - lw
  return mx >= lx and mx < lx + lw
     and my >= sy + 2 and my < sy + 2 + LINE_H
end

local function seg_hovered(doc, item, seg_x, seg_w)
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  return mx >= doc.ox + seg_x and mx < doc.ox + seg_x + seg_w
     and my >= sy and my < sy + LINE_H
end

local function inline_link_hovered(doc, item)
  if not item.lregs or #item.lregs == 0 then return nil end
  local mx, my = mouse()
  local sy = doc.oy + item.y - doc.scroll_y
  if my < sy or my >= sy + LINE_H then return nil end
  for _, reg in ipairs(item.lregs) do
    if mx >= doc.ox + reg.x and mx < doc.ox + reg.x + reg.w then
      return reg.link
    end
  end
  return nil
end

-- -- public API ----------------------------------------------------------------

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
  doc.navigated_to = nil
  doc.copied        = false
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
      if item.tag == "link" and link_hovered(doc, item) then
        if item.url then
          doc.navigated_to = { url=item.url }
        else
          doc.navigated_to = { user=item.user, file=item.file }
        end
        break
      end
      if item.tag == "p" then
        local lnk = inline_link_hovered(doc, item)
        if lnk then
          if lnk.url then
            doc.navigated_to = { url=lnk.url }
          else
            doc.navigated_to = { user=lnk.user, file=lnk.file }
          end
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
    local item_h = item.h or LINE_H
    if y + item_h > oy and y < oy + doc.height + LINE_H then

      if item.tag == "h1" then
        print(item.text, ox + PAD_X, y, 7)
        line(ox + PAD_X, y+LINE_H-1, ox + PAD_X + #item.text*CHAR_W+2, y+LINE_H-1, 5)

      elseif item.tag == "h2" then
        print(item.text, ox + PAD_X, y, 12)

      elseif item.tag == "link" then
        local col = link_hovered(doc, item) and 29 or 30
        print(item.text, ox + PAD_X, y, col)
        line(ox + PAD_X, y+LINE_H-1, ox + PAD_X + measure(item.text)-1, y+LINE_H-1, col)

      elseif item.tag == "code" then
        rectfill(ox+PAD_X-2, y, ox+PAD_X+doc.cont_w+2, y+item.h-1, 0)
        rect    (ox+PAD_X-2, y, ox+PAD_X+doc.cont_w+2, y+item.h-1, 5)
        local lw = measure("copy")
        local lx = ox + PAD_X + doc.cont_w - lw
        print("copy", lx, y+3, copy_hovered(doc, item) and 7 or 5)
        for li, code_line in ipairs(item.lines) do
          print(code_line, ox+PAD_X+2, y+3+(li-1)*LINE_H, 11)
        end

      elseif item.tag == "img" then
        local ix = ox + flr((doc.width - item.w) / 2)
        if item.src_w == item.w and item.src_h == item.h then
          spr(item.sprite, ix, y)
        else
          sspr(item.sprite, 0, 0, item.src_w, item.src_h, ix, y, item.w, item.h)
        end

      elseif item.tag == "p" and item.segs then
        local sx = PAD_X
        for _, seg in ipairs(item.segs) do
          local sw = measure(seg.text)
          if seg.link then
            local tw = measure((seg.text):match("^(.-)%s*$"))
            local col = seg_hovered(doc, item, sx, tw) and 29 or 30
            print(seg.text, ox + sx, y, col)
            line(ox + sx, y+LINE_H-1, ox + sx + tw - 1, y+LINE_H-1, col)
          else
            print(seg.text, ox + sx, y, 6)
          end
          sx += sw
        end

      else
        print(item.text, ox + PAD_X, y, 6)
      end
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
