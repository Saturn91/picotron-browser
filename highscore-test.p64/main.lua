-- highscore-test: scoresub playground

local W, H      = 240, 180
local TABLE     = "hs_test_1"

local score     = 0
local scores    = {}
local my_entry  = nil
local msg       = ""
local msg_timer = 0

local function find_my_entry(list)
  local uid = stat(64)
  if not uid or uid == 0 then return nil end
  for _, e in ipairs(list) do
    if e.user_id == uid then return e end
  end
  return nil
end

function _init()
  window { width=W, height=H, title="scoresub test" }
  scores   = scoresub(TABLE) or {}
  my_entry = find_my_entry(scores)
end

function _update()
  if btnp(5) then
    score += 1
  end

  if btnp(4) then
    scores    = scoresub(TABLE, score, "muh") or {}
    my_entry  = find_my_entry(scores)
    msg       = "submitted " .. score .. "!"
    msg_timer = 180
  end

  if msg_timer > 0 then
    msg_timer -= 1
    if msg_timer == 0 then msg = "" end
  end
end

function _draw()
  cls(0)

  -- leaderboard: top left
  print("leaderboard", 4, 4, 6)
  line(4, 12, 110, 12, 5)
  local ly = 15
  if #scores == 0 then
    print("no scores yet", 4, ly, 5)
  end
  for i, e in ipairs(scores) do
    if i > 8 then break end
    spr(e.icon, 4, ly)
    local rank_col = i == 1 and 10 or 7
    print(i .. ". " .. e.username, 20, ly + 2, rank_col)
    print(e.score, 100, ly + 2, rank_col)
    if e.extra and e.extra ~= "" then
      print(e.extra, 20, ly + 9, 5)
    end
    ly += 20
  end

  -- current score: center
  local cx = flr(W / 2)
  local label = "score: " .. score
  local lw    = print(label, 0, -100)
  print(label, cx - flr(lw / 2), 78, 11)
  print("x: +1", cx - 20, 90, 5)
  print("o: submit", cx - 20, 98, 5)

  -- personal best
  if my_entry then
    local pb = "your best: " .. my_entry.score
    local pw = print(pb, 0, -100)
    print(pb, cx - flr(pw / 2), 112, 6)
    local ex = "extra: " .. (my_entry.extra or "-")
    local ew = print(ex, 0, -100)
    print(ex, cx - flr(ew / 2), 121, 5)
  end

  -- logged-in user hint
  local uid = stat(64)
  if uid and uid ~= 0 then
    local uname = stat(65) or "?"
    print("logged in as: " .. uname, 4, H - 10, 5)
  else
    print("not logged in", 4, H - 10, 8)
  end

  -- submitted message: top right
  if msg ~= "" then
    local mw = print(msg, 0, -100)
    print(msg, W - mw - 4, 4, 10)
  end
end
