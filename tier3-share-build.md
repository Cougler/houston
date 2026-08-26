# Tier-3 Public Share Links — Build Notes

> Captured 2026-08-25, from planning discussion before implementation.
> Extends the "Public share links" section of `featureideas.md`. Read that
> first for the product framing (differentiators, sequencing); this file is
> the infra/security/monetization decisions layered on top.

Guiding priorities for every tradeoff below, in the order Aaron gave them:
**security → flexibility → user experience.**

## Infrastructure

- **Relay: Hetzner Cloud VPS**, CPX11 (2 vCPU AMD, 2GB RAM, 40GB SSD,
  ~$18/mo) or equivalent. Runs an frp/sish-style tunnel server that Houston
  connects to outbound over 443 (NAT-proof, matches `featureideas.md`).
  Sized generously for this workload — routing/TLS-termination for
  Host-header-based multiplexing is lightweight; bandwidth and DDoS
  exposure are the real ceilings, not CPU/RAM, and Hetzner's included
  traffic + baseline network-edge DDoS mitigation cover hobby-to-early-growth
  scale without extra setup.
- **DNS: Cloudflare, proxy OFF ("DNS only" / grey-cloud).** The bought share
  domain's nameservers point at Cloudflare purely so Caddy/acme.sh can do
  DNS-01 wildcard cert issuance/renewal against Cloudflare's DNS API. No
  live share traffic ever routes through Cloudflare's proxy — everything
  (Host-header routing, PIN check, path-blocking, parking page, future
  comment-overlay injection) runs on the Hetzner box, fully Houston-owned.
  Rejected alternative: Cloudflare Tunnel + Workers — would've given
  overlay injection (`HTMLRewriter`) and edge PIN-gating for free, but
  trades away relay ownership and makes Houston's uptime/positioning
  ("Houston owns both tunnel and agent") dependent on Cloudflare's platform
  and ToS enforcement.
- **Wildcard cert is a security property, not just convenience**: individual
  share subdomains never appear in public Certificate Transparency logs
  (a per-subdomain cert would leak them). Keep the wildcard-cert approach
  even if per-tenant cert issuance ever looks simpler.

## Monetization

- Gate the feature that costs money, not the app. Local features (terminal
  hosting, sidebar, `.localhost`/`.local` sharing) cost Houston nothing
  per-user and should stay free / one-time-purchase. Public share links
  require the relay, so that's the natural metering point — and the only
  one that's actually enforceable, since the repo is public
  (`Cougler/houston`) and any client-side license check is trivially
  stripped by building from source. The relay refusing to issue a tunnel
  without an active subscription is a server-side check with no client-side
  workaround.
- Target **$9–12/mo** subscription for the share-link tier, in line with
  where ngrok's personal/custom-domain tiers sit, justified further by the
  safety defaults (PIN, expiry, kill switch, visitor log) and eventual
  comment-loop feature bundled in.
- Matches `featureideas.md`'s own instinct: "free 1-hour links, paid
  persistent named subdomains... Plausibly Houston's first revenue."
- Mechanics: Stripe Billing/Checkout for the subscription itself (card
  storage, dunning, cancellation — don't build this). A thin account layer
  (can live on the Hetzner box or a small serverless function) does
  sign-in → token issuance, Stripe webhook → subscription status in a small
  DB, relay → checks status before handing out a tunnel. App stores the
  token locally; lapsed subscription only affects new tunnel requests, rest
  of the app is untouched.

## Security requirements (non-negotiable before calling this trustworthy)

1. **PIN must be mandatory by default and rate-limited.** Friendly/memorable
   share names (a stated UX delight) are inherently more guessable than
   random tokens — the PIN is what actually protects against that
   tradeoff. A 4-digit PIN is only 10,000 combinations; lock out or
   heavily throttle after a handful of failed attempts per IP, or it's
   brute-forceable.
2. **Unmatched Host headers on the public relay must return a generic
   404 — never a listing of other active shares.** The local
   `ShareProxy.swift` pattern (`listingPage()` enumerating every routed
   project on a miss) is fine on a single user's own Mac but becomes a
   real cross-tenant leak if reused verbatim on the shared public relay.
   Do not carry that function over as-is.
3. **Never put the PIN or a session token in the URL.** Query-string
   secrets end up in browser history, server logs, and leak to third-party
   scripts the shared app loads via the `Referer` header. Exchange the PIN
   via a form POST into a cookie; set `Referrer-Policy: no-referrer` on
   relay-injected responses.
4. **Path-blocking (`/.env`, `/.git/`, etc.) is a bonus, not the defense.**
   It's a blocklist and can't be exhaustive — a random dev server can leak
   secrets through paths nobody thought to block. PIN + expiry + visitor
   log + kill switch are the actual security boundary.
5. **Relay-side rate limiting per IP and per tenant**, independent of the
   PIN throttle above — it's a shared box across every user's live share;
   one noisy tenant or attacker shouldn't degrade everyone else's links.
6. **Be honest that TLS terminates at the relay.** Required to support
   overlay injection later, but it means the relay (Houston's
   infrastructure) sees plaintext of everything flowing through an active
   share. The trustworthy claim is "random internet strangers can't reach
   this without the PIN," not "not even the relay sees the bytes" — don't
   oversell the latter to enterprise prospects.
7. **Comment-overlay injection (later phase) needs its own scoping pass**
   when built: the injected script runs in-origin in the visitor's
   browser, so comments must be strictly scoped to the correct share
   session, and dev servers with their own CSP may need nonce-aware
   injection rather than a bare inline `<script>`.

## UX / flexibility notes

- Memorable share names (not `quiet-lion-7f3a`) are worth keeping as a
  delight *only because* the PIN requirement above offsets the guessability
  cost — don't ship one without the other.
- Default 1-hour expiry (extendable), QR code in the share popover, framed
  viewer with a friendly "prototype offline" parking page on disconnect —
  all still the plan per `featureideas.md`.
- Live visitor log + one-click kill switch double as both a UX feature
  (Aaron sees who's viewing) and the primary leak-response mechanism if a
  link gets out further than intended.

## Open / deferred

- Per-user tunnel provisioning details (one Hetzner relay instance can
  serve many users' tunnels; account/token plumbing needs designing
  alongside the Stripe integration).
- Hand-rolled Go relay (path-blocking, PIN, overlay injection all living
  inside it) vs. off-the-shelf frp/sish plus a thin layer in front —
  `featureideas.md`'s "Start" vs. "Later" phases still apply; this file
  doesn't change that sequencing, only the hosting/DNS choice.
