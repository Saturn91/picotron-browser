# Comment Section — Design Document

## Overview

A per-page comment system for podweb pages, backed by a Cloudflare Worker.
Each authenticated Picotron user can leave one comment per page (last write wins).
Comments are scoped to the page owner's podnet identity, and opt-in is verified
server-side via a capability file the owner publishes to their own podnet.

---

## Tag Syntax

```
[comment uid=XXXXX]
[comment uid=XXXXX server=https://your-own-server.com]
```

| Attribute | Required | Description |
|-----------|----------|-------------|
| `uid`     | yes      | Lexaloffle user ID of the page owner |
| `server`  | no       | Override backend URL (default: the reference Cloudflare Worker) |

The `server` attribute lets anyone self-host the backend and use the same
tag format. If the default server ever goes down, page authors simply add
`server=` pointing to an alternative.

---

## How to Enable Comments on Your Podweb

Two steps, done once:

**1. Publish the capability file to your podnet:**
```lua
store("podnet://" .. stat(64) .. "/comment_enabled_for_podweb.true", "true")
```

**2. Add the tag to your page:**
```
[comment uid=16423]
```

To disable comments, either delete the capability file or set its content to
anything other than `"true"`.

---

## Security Model

### Browser-side (client)

Before rendering the comment box, the browser checks:
- The uid in the tag **matches** the uid in the current page's podnet URL

```
current URL:  podnet://16423/my-page.podweb
tag:          [comment uid=16423]   ✓ match → render
tag:          [comment uid=9999]    ✗ mismatch → skip silently
```

This prevents a malicious author from embedding someone else's comment section
into their own page to harvest comments under a different identity.

### Backend-side (Cloudflare Worker)

On every POST the Worker:
1. Fetches `https://podnet.flp.io/{uid}/comment_enabled_for_podweb.true`
2. Checks the response body equals `"true"`
3. Only then writes the comment to KV

Because only the podnet owner can write to their own podnet, the presence of
that file with `"true"` is unforgeable proof of opt-in. No API keys or
registration needed.

---

## Login Requirement

The comment input is only rendered when the user is logged in:

```lua
if stat(64) ~= 0 then
  -- render input box and submit button
end
```

When not logged in the section shows existing comments read-only with no
footer or prompt. The comment entry is stamped with:

```lua
stat(64)  -- user ID   (used as the KV sub-key → enforces one comment per user)
stat(65)  -- username  (displayed next to the comment)
stat(66)  -- icon      (drawn via spr() next to the username)
```

---

## Data Flow

### Reading comments (on page load)

```
Browser
  └─ GET {server}/comments?uid={uid}&page={page_slug}
       └─ Worker returns JSON: [ {user_id, username, text, time}, ... ]
```

### Posting a comment

```
Browser
  └─ POST {server}/comments
       body: { uid, page, user_id, username, text }
       └─ Worker fetches podnet.flp.io/{uid}/comment_enabled_for_podweb.true
            ├─ "true"  → upsert KV[{uid}:{page}][user_id] → 200 OK
            └─ other   → 403 Forbidden
```

---

## Backend — KV Structure

```
Key:   "{uid}:{page_slug}"
Value: {
  "16423": { "username": "zep",   "text": "Nice work!", "time": 1745000000 },
  "8821":  { "username": "alice", "text": "Love this.", "time": 1745001234 }
}
```

- `uid` = page owner's Lexaloffle ID (from the tag)
- `page_slug` = filename without extension (e.g. `my-page` from `my-page.podweb`)
- Sub-key = commenter's `user_id` → enforces one entry per commenter per page

---

## Rendered Component — ASCII Mockup

### Logged in, comments present

```
╔══════════════════════════════════════════╗
║  Comments                                ║
╠══════════════════════════════════════════╣
║                                          ║
║  [▓▓] zep                  2026-04-20   ║
║       "Great page! Love the pixel art."  ║
║                                          ║
║  [▓▓] alice                2026-04-21   ║
║       "Very cool project, bookmarked."   ║
║                                          ║
║  [▓▓] bob                  2026-04-22   ║
║       "How did you make the scrolling?"  ║
║                                          ║
╠══════════════════════════════════════════╣
║  [▓▓] you                               ║
║  ┌──────────────────────────────────┐   ║
║  │ write a comment...               │   ║
║  └──────────────────────────────────┘   ║
║                             [ submit ]  ║
╚══════════════════════════════════════════╝
```

### Logged in, comment already submitted

```
╔══════════════════════════════════════════╗
║  Comments                                ║
╠══════════════════════════════════════════╣
║  [▓▓] zep                  2026-04-20   ║
║       "Great page! Love the pixel art."  ║
║                                          ║
║  [▓▓] you                  2026-04-23   ║
║       "Awesome stuff!"                   ║
╠══════════════════════════════════════════╣
║  [▓▓] you                               ║
║  ┌──────────────────────────────────┐   ║
║  │ Awesome stuff!                   │   ║
║  └──────────────────────────────────┘   ║
║                             [ update ]  ║
╚══════════════════════════════════════════╝
```

### Not logged in

```
╔══════════════════════════════════════════╗
║  Comments                                ║
╠══════════════════════════════════════════╣
║  [▓▓] zep                  2026-04-20   ║
║       "Great page! Love the pixel art."  ║
║                                          ║
║  [▓▓] alice                2026-04-21   ║
║       "Very cool project, bookmarked."   ║
╚══════════════════════════════════════════╝
```

### Capability file missing (owner hasn't opted in)

```
╔══════════════════════════════════════════╗
║  Comments                                ║
╠══════════════════════════════════════════╣
║  Comments are not enabled for this page. ║
╚══════════════════════════════════════════╝
```

---

## Page Slug Derivation

The page slug is extracted from the podnet URL of the currently viewed page:

```
podnet://16423/my-cool-page.podweb  →  slug = "my-cool-page"
podnet://16423/index.podweb         →  slug = "index"
```

This means each podweb file gets its own isolated comment thread.

---

## Known Vulnerabilities & Risk Acceptance

The current design has known weaknesses. They are documented here rather than
fixed, because the mitigations either require infrastructure that doesn't exist
(Picotron has no server-readable authentication API) or are disproportionate
for a hobby project.

### Attack surface summary

| Attack | What it allows | Effort | Mitigation |
|---|---|---|---|
| Raw HTTP POST | Inject a comment into any opted-in page as any claimed username | Low | 10s IP rate limit (speed bump only) |
| Identity spoofing | Claim to be any user in the POST body — worker trusts it blindly | Low | Nonce flow (see below) or accept risk |
| `server=` exfiltration | A malicious page author collects commenter identities & text on their own server | Medium | Warn authors in docs |

### Why scoresub can't help

Scoresub is a Picotron Lua API — there is no public HTTP endpoint the Worker
can call to verify a user's identity. The Worker can only read podnet files via
`https://podnet.flp.io/{user_id}/{filename}`.

### Optional: nonce-based identity proof

If identity spoofing needs to be closed, the client can prove ownership of a
`user_id` by writing a short-lived nonce to their own podnet (only the real
owner can do this), then including it in the POST for the Worker to verify.

```
1. Client generates a nonce (random string + current timestamp)
2. Client writes:  podnet://{stat(64)}/comment_nonce.txt  ←  nonce
3. Client POSTs:   { uid, page, user_id, username, text, nonce }
4. Worker fetches: podnet.flp.io/{user_id}/comment_nonce.txt
5. Worker checks:  body matches nonce AND timestamp is < 30s old
6. On success:     accept comment, client deletes nonce file
```

Downsides: extra podnet write before every comment (slow), more client code.
Not implemented in v1 — ship without it and add if abuse becomes a problem.

### Rate limiting

The Worker enforces a 10-second cooldown per IP address using a KV counter.
This stops spam floods but not a determined attacker with rotating proxies.
Implemented via a `rl:{ip}` KV key with a 10s TTL.

---

## Self-Hosting the Backend

Anyone can run their own compatible backend. The Worker contract is:

```
GET  /comments?uid={uid}&page={page}
     → 200 JSON array of { user_id, username, text, time }

POST /comments
     body: { uid, page, user_id, username, text, nonce? }
     → 200 on success
     → 403 if capability file missing or not "true"
     → 429 if rate limited (60s per IP)
```

Point `server=` at your own deployment and the browser will use it instead.
