# Session policy — sign-in lifetime, storage posture, and the janitor

How long a MULTI/DEX sign-in lasts, where the session lives, and the machinery
that ends it. Code: `src/frontend/src/main.js` (auth section: `login`,
`doLogin`, `startSessionHeartbeat`, `tabsAllClosedSinceLastLoad`,
`registerJanitorSW`), `src/frontend/public/sw.js` (the janitor worker), and
the `#signin-modal` dialog in `src/frontend/index.html`.

## What a "session" is

Internet Identity issues a **delegation**: a chain signed by the user's II
identity that empowers a locally generated **base session key** until an
expiry baked into the delegation (`maxTimeToLive`, checked by the replica on
every call — a hard, cryptographic cap that nothing client-side can extend).
The pair (base key + delegation) is held by `@icp-sdk/auth`'s AuthClient in
one of two places, chosen at sign-in:

- **On disk (default)** — IndexedDB (`auth-client-db` / `ic-keyval`). The base
  key is a **non-extractable WebCrypto ECDSA key**: page JavaScript (and
  therefore XSS) can use it but never read it out. Survives reloads and
  browser restarts, up to the TTL.
- **In memory** — a plain JS `Map` passed as custom `AuthClientStorage`.
  Nothing ever touches disk, so there is no forensic trace to recover; the
  session ends on tab close *or refresh* by construction. The key object is
  still a non-extractable CryptoKey (unlike a sessionStorage-backed store,
  which can only hold strings and would force a weaker, serializable key).

## The sign-in dialog

Every Sign In button opens `#signin-modal` with two independent controls,
both remembered in localStorage for next time:

1. **Max session length** — 20 min / 1 h (default) / 8 h / 1 day. Becomes the
   delegation's `maxTimeToLive`. This is the cap *while a tab stays open*,
   and also the outer bound on how long any recovered-from-disk artifact
   could be abused (see Security notes).
2. **In-memory session key only** (checkbox) — the storage posture above.
   Because storage is bound at `AuthClient.create()` time, `doLogin()`
   rebuilds the client with the chosen storage before opening the II window.

## When a session ends

| Event | On-disk session | In-memory session |
|---|---|---|
| Tab refresh | survives | **ends** (memory gone) |
| Close one of several tabs | survives | n/a (per-tab) |
| Close **all** tabs | **ends** (heartbeat check at next load; bytes also deleted ~8 s later by the janitor SW) | ends |
| 1 h with no mouse/key/touch in an open tab | **ends** (AuthClient IdleManager, `idleTimeout` 1 h) | ends |
| Max session length reached | **ends** (replica rejects the delegation) | ends |
| Browser quit / crash / mobile app swipe | delegation bytes remain on disk until next visit (then the heartbeat check ends the session) — usable at most until the TTL | ends |

## Close-all-tabs: two layers

### Layer 1 (authoritative): heartbeat + boot stale-check

Every open tab writes `mdx.tabHeartbeat = Date.now()` to localStorage **every
second** (`HEARTBEAT_MS`), plus on `visibilitychange`/`pageshow`. At boot,
*before* this tab restarts the heartbeat, `tabsAllClosedSinceLastLoad()`
inspects the last value:

- gap ≤ 8 s (`SESSION_STALE_MS`) → a refresh/navigation → session kept;
- gap > 8 s (or no key) → every tab was closed → `authClient.logout()`.

All of the logic runs at page load, which always executes — so it covers tab
close, browser quit, crashes, and mobile app swipes alike. Multi-tab is safe:
any surviving tab keeps the heartbeat fresh.

**Why the write is synchronous on purpose.** localStorage writes block the
main thread, but a single ~13-byte `setItem` costs microseconds at 1 Hz —
unmeasurable. Wrapping it in `setTimeout(0)` would run the *same* synchronous
write on the *same* thread one task later (no saving), and deferring via
`requestIdleCallback` could starve on busy pages, letting the heartbeat go
stale while a tab is open — which would turn the next refresh into a false
logout. Prompt beats polite here; don't "optimize" this.

### Layer 2 (hygiene): the janitor service worker

`public/sw.js` deletes the on-disk session bytes ~8 s after the last tab
closes, rather than leaving them until the next visit.

Design: **rolling census, not a pagehide ping.** The heartbeat also posts
`{type:"alive"}` to the worker every second; *each* ping opens an
`event.waitUntil` timer that, 8 s later (`GRACE_MS`), counts live app tabs
via `clients.matchAll`. While tabs live, every census sees one and no-ops.
When the last tab closes, the most recent routine ping — delivered *before*
the close, so no teardown race — is still pending; its census finds zero
tabs and runs `indexedDB.deleteDatabase("auth-client-db")` (equivalent to
`AuthClient.logout()`'s storage clear; DB/store names from
`@icp-sdk/auth`'s `client/db.js`).

Two hard-won lessons encoded here:

- A message posted **during `pagehide` of the final tab races renderer
  teardown and is often lost** (observed in production: sessions survived).
  A worker with zero clients also isn't kept alive to *receive* anything —
  but an **already-received** event held open by `waitUntil` legitimately
  outlives the last client (Chromium allows ~5 min; WebKit/Gecko comfortably
  cover 8 s). Hence rolling pings: the triggering event always predates the
  close.
- The worker can never cause a false logout: it only acts on a truly empty
  census, and a reload reappears in `clients.matchAll` well inside the grace
  window (`includeUncontrolled: true` counts a just-reloaded page that isn't
  controlled yet).

Failure mode: browser quit / crash / app swipe kills the worker mid-wait —
the bytes stay until Layer 1 ends the session at the next visit, and the TTL
bounds their usefulness meanwhile.

**Mobile:** the janitor uses only baseline SW API (message, waitUntil,
clients.matchAll, IndexedDB — deliberately *not* Background Sync, which is
Chromium-only), so it works on Android Chrome/Firefox and iOS WebKit (all
iOS browsers). Background-tab timer throttling stretches the ping cadence,
so a tab closed after long backgrounding may have no census pending — Layer 1
catches it.

## Security notes

- **Deletion ≠ erasure.** IndexedDB rides on append-only storage engines
  (LevelDB/SQLite) over filesystems and SSDs that don't scrub freed blocks —
  no web app can guarantee physical erasure, and overwrite-with-junk buys
  nothing (the overwrite is appended elsewhere). The honest bounds are: the
  **TTL** (a recovered delegation is cryptographically dead after it), the
  **in-memory mode** (nothing on disk to recover), and full-disk encryption
  on the machine (the operator's job).
- The idle logout (1 h) and TTL are enforced by the AuthClient and the
  replica respectively; the janitor layers are about not leaving live
  sessions or bytes behind on shared machines.

## Constants

| Constant | Value | Where |
|---|---|---|
| `maxTimeToLive` | 20 min–1 day (dialog) | `doLogin`, main.js |
| `idleTimeout` | 1 h | `IDLE_OPTS`, main.js |
| `HEARTBEAT_MS` | 1 s | main.js |
| `SESSION_STALE_MS` | 8 s | main.js |
| `GRACE_MS` | 8 s | public/sw.js |

`SESSION_STALE_MS`/`GRACE_MS` trade refresh-tolerance against logout latency:
both must exceed a slow reload's dead time; a close-and-reopen faster than
them is indistinguishable from a refresh and keeps the session.
