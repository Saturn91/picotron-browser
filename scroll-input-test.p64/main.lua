-- scroll-input-test: hidden widget + mock field pattern

local W, H         = 480, 270
local scroll_y     = 0
local max_scroll   = 0
local frame        = 0

local DOC_X        = 10
local LINE_H       = 12
local NUM_LINES    = 30

-- mock field layout (document space)
local FIELD_DOC_Y  = 120
local FIELD_W      = 200
local FIELD_H      = 14
local FIELD_PAD    = 3   -- text padding inside field

local gui          = nil
local txt          = nil
local focused      = false
local prev_mb      = 0

function _init()
  window { width = W, height = H, title = "scroll input test" }

  max_scroll = (NUM_LINES * LINE_H + 60) - H

  gui = create_gui()
  txt = gui:attach_text_editor {
    x      = -500,
    y      = -500,
    width  = FIELD_W,
    height = FIELD_H,
  }
end

local function mock_field_screen_y()
  return FIELD_DOC_Y - scroll_y
end

local function is_over_mock_field()
  local mx, my = mouse()
  local sy = mock_field_screen_y()
  return mx >= DOC_X and mx <= DOC_X + FIELD_W
     and my >= sy    and my <= sy + FIELD_H
end

function _update()
  frame += 1

  local _, _, _, wy = mouse()
  scroll_y = mid(0, scroll_y - wy * 4, max_scroll)

  if btnp(2) then scroll_y = mid(0, scroll_y - LINE_H, max_scroll) end
  if btnp(3) then scroll_y = mid(0, scroll_y + LINE_H, max_scroll) end

  local _, _, mb = mouse()
  local clicked = (prev_mb & 1) == 0 and (mb & 1) == 1
  local focus_request = nil

  if clicked then
    if is_over_mock_field() then
      focused        = true
      focus_request  = true
    else
      focused        = false
      focus_request  = false
    end
  end
  prev_mb = mb

  gui:update_all()

  -- set after update_all so it isn't overridden by click processing
  if focus_request ~= nil then
    txt:set_keyboard_focus(focus_request)
  end
end

function _draw()
  cls(1)
  clip(0, 0, W, H - 20)

  -- scrollable document lines
  for i = 1, NUM_LINES do
    local sy = (i - 1) * LINE_H - scroll_y
    if sy > -LINE_H and sy < H then
      print("line " .. i, DOC_X, sy, 7)
    end
  end

  -- mock input field
  local sy      = mock_field_screen_y()
  local visible = sy + FIELD_H > 0 and sy < H - 20

  if visible then
    local border_col    = focused and 6 or 5
    local lines         = txt:get_text()
    local content       = (lines and lines[1]) or ""
    local cur_x         = txt:get_cursor()
    local before        = string.sub(content, 1, cur_x - 1)
    local cursor_pixel  = print(before, 0, -100)
    local field_inner_w = FIELD_W - FIELD_PAD * 2

    -- shift text left enough to keep cursor in view
    local text_offset = max(0, cursor_pixel - field_inner_w + 4)

    local inner_x = DOC_X + FIELD_PAD
    local inner_y = sy + FIELD_PAD

    rectfill(DOC_X,     sy,     DOC_X + FIELD_W,     sy + FIELD_H, 2)
    rect    (DOC_X - 1, sy - 1, DOC_X + FIELD_W + 1, sy + FIELD_H + 1, border_col)

    -- clip to field interior, draw shifted text, restore doc clip
    clip(inner_x, sy + 1, inner_x + field_inner_w, sy + FIELD_H - 1)
    print(content, inner_x - text_offset, inner_y, 7)

    -- blinking cursor at actual position
    if focused and (frame % 30) < 15 then
      local px = inner_x + cursor_pixel - text_offset
      rectfill(px, inner_y, px + 2, inner_y + 6, 7)
    end

    clip(0, 0, W, H - 20)
  end

  clip()
  gui:draw_all()

  -- get_cursor debug: top right
  local cx, cy = txt:get_cursor()
  local cur_str = "cursor=(" .. tostring(cx) .. "," .. tostring(cy) .. ")"
  local tw = print(cur_str, 0, -100)
  print(cur_str, W - tw - 4, 4, 6)

  -- debug bar
  local lines   = txt:get_text()
  local content = (lines and lines[1]) or ""
  rectfill(0, H - 20, W - 1, H - 1, 0)
  line(0, H - 20, W - 1, H - 20, 5)
  print(
    "click field to focus  scroll_y=" .. scroll_y ..
    "  focused=" .. tostring(focused) ..
    "  text=\"" .. content .. "\"",
    4, H - 13, 6
  )
end
