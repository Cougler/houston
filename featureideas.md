# Houston — Feature Ideas

---

## Shareable local dev URLs ("LocalDock, but a product")

*Captured 2026-08-24. Inspired by https://www.localdock.dev/ — pretty
localhost names + tunnels. Thesis: the tunnel is a commodity (ngrok, frp,
sish all solve it); nobody has built the **sharing experience** around it for
non-technical people. Houston is uniquely positioned because it already
detects every dev server (project name + port) and owns the agent session.*

### The three tiers

1. **`<project>.localhost`** — local-only pretty names. A reverse proxy on
   port 80 (fallback high port) routes by Host header to the detected dev
   port. Works because browsers resolve `*.localhost` → 127.0.0.1 by
   standard (RFC 6761); macOS allows unprivileged port-80 binding since
   Mojave. Byte-splice after the first request's Host header and WebSockets/
   HMR/SSE work for free. ~A day of work; pure local code.
2. **`<project>.local`** — Wi-Fi reach via Bonjour/mDNS advertisement, for
   phone testing and colleagues. Caveat: dev server must bind beyond
   loopback.
3. **Public share links** — Houston keeps one outbound connection (over 443,
   NAT-proof) to a relay VPS holding a wildcard TLS cert; relay routes
   `hierarch-demo.<domain>` down the tunnel.

### Domain decision

Buy a **separate short domain** for shared content (the `houst.live` genre) —
NOT a subdomain of tryhoustonapp.com. Same reason GitHub uses
githubusercontent.com: cookie isolation between users' content and the main
site, and abuse/reputation blast radius stays off the brand. Ideally on the
Public Suffix List. ~$15/yr.

### The differentiators (in order of conviction)

1. **The share is a page, not a raw tunnel.** Visitors get a thin frame:
   "You're viewing Aaron's live prototype — it may go offline." Laptop
   sleeps → friendly "prototype offline" parking page with "notify me when
   it's back", not a 502.
2. **Click-to-comment on the live prototype.** Overlay injected by the
   relay; client pins a comment anywhere, no account. Comments flow back
   into Houston — into `tasklist.md` or straight into the running Claude
   session. *Client comments → agent fixes → client refreshes and sees it.*
   The loop nobody else can build; Houston owns both tunnel and agent.
3. **Safety defaults ngrok doesn't bother with.** 4-digit PIN interstitial
   on by default; 1-hour expiry (extendable) surfaced through the tracked/
   notifications system; live visitor log + kill switch in Houston;
   relay-side blocking of `/.env`, `/.git/` etc. ("we won't serve your
   secrets even if your dev server would").
4. **Delights.** QR code in the share popover, memorable names (not
   `quiet-lion-7f3a`), a "share" skill ("share this with my client for the
   afternoon").

### Infrastructure path

- **Start:** off-the-shelf tunnel server (frp or sish, both OSS) on a
  ~$20/mo VPS; wildcard cert via Let's Encrypt DNS-01. Days to market.
- **Later:** hand-roll the relay (Go is the usual choice; frp is readable
  reference) once features demand it — the interstitials, PIN check, path
  blocking, visitor log, and comment injection all live *inside* the relay,
  and generic tools fight you on them. A relay is a well-trodden pattern
  (accept client control connections, terminate TLS, route by Host header,
  multiplex streams): a few focused weeks, a few thousand lines. Houston's
  client side barely changes, so the swap is invisible to users.

### Honest costs

- **Abuse:** public tunnels attract phishing. Short default expiry,
  interstitial banner, bandwidth caps, report link; keep ephemeral links
  anonymous but gate long-lived ones behind an account. Ongoing chore.
- **Bandwidth:** fine at hobby scale; naturally becomes the paid tier —
  free 1-hour links, paid persistent named subdomains. Plausibly Houston's
  first revenue.

### Sequencing

1. `*.localhost` local proxy (LocalDock tier-1 clone) — ships fast,
   immediately useful
2. Relay + bought domain + one-click share (PIN, expiry, QR, framed viewer)
3. Click-to-comment → tasklist/Claude integration — the differentiator,
   once 2 proves usage

---
