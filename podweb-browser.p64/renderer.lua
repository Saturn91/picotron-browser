--[[pod_format="raw",created="2026-04-19 10:20:40",modified="2026-04-20 21:08:13",revision=1,xstickers={}]]
-- Browser chrome: address bar and reload button
-- Brower chrome: address bar and reload button

function is_over_button(b)
  local mx, my = mouse()
  return mx >= b.x and mx < b.x + b.w
     and my >= b.y and my < b.y + b.h
end

function draw_button(b)
  local hovered = not b.disabled and is_over_button(b)
  local bg      = b.disabled and 1 or (hovered and 6 or 2)
  rectfill(b.x, b.y, b.x+b.w-1, b.y+b.h-1, bg)
  if b.sprite then
    spr(b.sprite, b.x, b.y)
  else
    rect(b.x, b.y, b.x+b.w-1, b.y+b.h-1, 5)
    local tx = b.x + flr((b.w - #b.label * 4) / 2)
    local ty = b.y + flr((b.h - 5) / 2)
    print(b.label, tx, ty, hovered and 0 or 6)
  end
end

function draw_address_bar()
  rectfill(0, 0, W-1, BAR_H-1, 0)
  draw_button(RELOAD_BTN)
  BACK_BTN.disabled    = hist_idx <= 1
  FORWARD_BTN.disabled = hist_idx >= #history
  draw_button(BACK_BTN)
  draw_button(FORWARD_BTN)
  draw_button(COPY_BTN)
  draw_button(SUBMIT_BTN)
  line(0, BAR_H, W-1, BAR_H, 5)
end
