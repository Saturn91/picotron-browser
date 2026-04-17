# Picotron Networking: scoresub & podnet

Introduced in **Picotron 0.3.0b**. Covers online high scores (`scoresub`) and user cloud storage (`podnet`).

---

## Login / Account

Picotron networking is tied to your **Lexaloffle forum account**.

- Log in via the in-app menu (top bar → "Log in")
- A code is shown — paste it in the browser window that opens to link your account
- Login is optional for playing, but required to submit scores or write to podnet
- Requires a valid Picotron license on the account

Each logged-in user has three associated values:

| stat | returns |
|------|---------|
| `stat(64)` | unique numeric user ID |
| `stat(65)` | username string |
| `stat(66)` | user icon (draw with `spr()`, not `print()`) |

---

## scoresub

A single function handles both submitting and fetching high scores.

### Submit a score

```lua
local results = scoresub("table_name", score, extra)
```

- `"table_name"` — name of the high score list (scoped to your cartridge; no conflicts between carts)
- `score` — numeric value (sorted highest → lowest automatically)
- `extra` — optional string, up to **1024 characters**

### Fetch scores without submitting

```lua
local results = scoresub("table_name")
```

### Return value

`scoresub` returns a table of up to **64 entries**, each containing:

| field | description |
|-------|-------------|
| `entry.user_id` | unique numeric ID |
| `entry.username` | display name |
| `entry.icon` | user icon (use `spr()` to draw) |
| `entry.score` | submitted score |
| `entry.extra` | attached string |

### Example: draw a leaderboard

```lua
local list_y = 10
local results = scoresub("highscores")
for entry in all(results) do
  spr(entry.icon, 4, list_y)
  print(entry.username .. "  " .. entry.score .. "  " .. (entry.extra or ""), 20, list_y)
  list_y += 10
end
```

### Rules & limitations

- Sorted **highest to lowest** — invert scores for "lower is better" games (e.g. golf)
- **One entry per user** — only the user's personal best is kept; old entries are overwritten
- Rate limited to roughly **one submission every 2 seconds**
- Score tables are **version-scoped**: uploading a new version to the BBS creates a fresh table (existing scores are not carried over)
- BBS/Splore version and local `.p64` version maintain **separate** score tables

---

## podnet

Each user gets their own cloud storage folder, publicly readable but only writable by the owner.

### Access pattern

```
podnet://<user_id>/<filename>
```

Also accessible from any web browser at the equivalent Lexaloffle URL.

e.g. https://podnet.flp.io/48932/domains.lookup

### Read a file

```lua
local text = fetch("podnet://16423/hello.txt")
```

You can read **any** user's podnet — just change the user ID.

### Write a file (own podnet only)

```lua
store("podnet://hello.txt", "your content here")
-- writes to the logged-in user's own podnet
```

### Key properties

- **Public read** — anyone (including web browsers) can fetch your files
- **Private write** — only you can write to your own podnet
- **Large capacity** — can store entire levels, game states, generated content
- No official size limit documented yet

---

## The `extra` field as a data channel

The 1024-character `extra` field on `scoresub` is intentionally generous and can be used creatively:

- Encode a **replay** of the playthrough
- Store a **final game state** or board snapshot
- Save a **winning build/deck** in roguelikes
- Use `pod()` / `unpod()` to serialize Lua tables into the field

---

## Abusing scoresub for multiplayer

Because `scoresub` is the only network primitive (aside from podnet), developers have built surprising things on top of it:

- **Chat rooms** — the `extra` field carries message text; submitting a score just above the current max pushes a new message to the top
- **Presence/position sharing** — encode `{time=t, x=x, y=y}` via `pod()` into `extra`, poll periodically, interpolate positions client-side
- **Turn-based multiplayer** — submit game state as `extra`; opponents poll and unpack

### Limitations to keep in mind

- ~1 submission per 2 seconds
- Delivery is not guaranteed — occasional lag or dropped submissions
- Not suitable for real-time action games; works well for turn-based or slow-paced games

---

## podnet creative possibilities

- **Level sharing** (Mario Maker style) — save levels to podnet, use scoresub to index who has new content
- **Seasonal / DLC content** — static carts that fetch fresh content from podnet at runtime
- **Cozy multiplayer** — Animal Crossing-style island visits; store island state in podnet
- **A Picotron-native web** — podnet files are browser-accessible, enabling a small self-contained internet

---

## Open questions (as of Picotron 0.3.0b)

- No admin backend for score tables — uploading a new BBS version wipes all scores
- No moderation tools for `extra` field content
- Behavior when exporting as `.exe` or hosting on itch.io is not yet defined
- Pico-8 integration details not yet announced (scoresub expected; podnet unlikely)
