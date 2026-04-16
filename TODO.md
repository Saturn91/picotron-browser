# Podweb Browser — TODO & Decisions

## Decisions

### .podweb Format
Plain text markup. Tags come in two forms:

**Inline (single line):**
```
[h1] My Page Title
[p] A short paragraph.
```

**Block (multiline):**
```
[p-]
This is a longer paragraph
that spans multiple lines.
[-p]
```

Supported tags (initial set): `h1`, `h2`, `p`
Future tags: `link`, `img`, `meta`, `code`, `hr`

---

### Addressing
- **Phase 1:** Numeric user IDs only — `podnet://16423/index.podweb`
- Default file: if no filename specified, fetch `index.podweb`
- **Phase 2 (future):** Domain name system via `[meta]` block (see below)

**Domain name concept:**
A page can declare a friendly name in a meta block:
```
[meta-]
domain: laserdesk
[-meta]
```
When a user visits a page that declares a domain, the browser stores the mapping locally (`domain → user_id`). Future navigations to `laserdesk` resolve via this local cache — no central server needed.

---

### Window
Resizable window. Content area reflows on resize.

---

## TODO

### Core — Parser
- [x] Implement inline tag parser (`[tag] content`)
- [x] Implement block tag parser (`[tag-] ... [-tag]`)
- [x] Handle unknown/unsupported tags gracefully (skip or show raw)
- [ ] Define and document the full `.podweb` spec in README

### Core — Renderer
- [x] Render `[h1]` — large/bold style (color + maybe bigger via stretched print)
- [x] Render `[h2]` — medium style
- [x] Render `[p]` — body text with **word wrap** (split at word boundaries to fit window width)
- [x] Scrolling — track `scroll_y` offset, only draw visible nodes
- [ ] Reflow on window resize

### Core — Navigation
- [x] Address bar UI — display current `user_id` + filepath
- [x] Input: type a numeric user_id to navigate
- [ ] Back / Forward — history as a stack of `{user_id, filepath}` pairs
- [x] Internal links `[link file=about.podweb]` — same user, different file
- [x] Cross-user links `[link user=99]` — navigate to another user's index

### Core — Networking
- [x] Fetch `index.podweb` from `podnet://<user_id>/index.podweb`
- [ ] Loading state — show spinner or "loading…" while fetch is in progress
- [ ] Error state — handle missing files gracefully ("page not found")

### Domain System (Phase 2)
- [ ] Parse `[meta-][-meta]` block and extract `domain:` value
- [ ] Store domain → user_id mapping locally (own podnet or local file)
- [ ] Resolve domain names in address bar before fetching
- [ ] Show resolved user_id when navigating via domain name

### UI / UX
- [x] Design address bar (top of window: back/fwd buttons + address input)
- [ ] Scrollbar indicator
- [ ] Bookmarks — save/load a list of `{label, user_id, filepath}` to own podnet
- [x] Homepage — default page shown on launch (own podweb page, or a directory)

### local builder / previewer / publish
- [ ] create a local previewer for local .podweb files
- [ ] add a publish function which will publish your page on your url (cmd started, not complete)

### Future / Stretch
- [x] `[link]` tag with clickable hit regions
- [x] `[img]` tag — pod-encoded sprite embedded in .podweb file
- [x] `[code]` tag — monospace / syntax-highlighted block
- [ ] `[hr]` tag — horizontal rule separator
- [ ] Browser itself hosted on podnet so updates propagate to users automatically
- [ ] Directory page — a well-known podnet page listing known sites