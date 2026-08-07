// ── Is this origin a genuine local development replica? ──────────────
//
// One predicate, two security-critical consumers:
//
//   1. `fetchRootKey()` (main.js). The root key is the ANCHOR of every
//      certificate check. fetchRootKey() ASKS THE HOST for that key and
//      installs whatever comes back — and on mainnet the IC HTTP gateway
//      proxies /api/v2/status, so the app would be taking the anchor FROM THE
//      PARTY BEING VERIFIED. A hostile gateway hands us its own key, signs a
//      forged head with the matching secret, and the page prints "certificate
//      VALID" while the copy promises it "does not even trust this website".
//      A development replica genuinely needs it (its key is per-instance and
//      cannot be baked in), so it stays available — but only there.
//
//   2. `disableTimeVerification` (ledger.js). A local replica advances IC time
//      per round rather than by wall clock, so the freshness window misfires
//      there. On a real network, waiving it lets an OLD certificate replayed
//      over an OLD head pass — which is exactly how a truncated tape stays
//      invisible. Off localhost the window must be enforced.
//
// Matched on the HOSTNAME, exactly — never as a substring of the URL — so
// `localhost.evil.example`, `notlocalhost`, `127.0.0.1.evil.example` and
// `https://evil.example/?host=localhost` are all correctly treated as REMOTE.
// This is the same rule as scripts/verify_ledger.mjs:59-64 (LOCAL_HOST); the
// two are deliberately identical and should be changed together.
export function isLocalReplicaHost(hostname) {
  const h = String(hostname == null ? "" : hostname).toLowerCase();
  return h === "localhost"
      || h === "127.0.0.1"
      || h === "::1"
      || h === "[::1]"
      || h.endsWith(".localhost");
}

// The origin this page was actually served from — which is also the origin
// every agent in the app talks to (`host: window.location.origin`), i.e. the
// host being verified. Fails CLOSED (treats the origin as remote) if there is
// no `window` or the read throws.
export function isLocalReplicaOrigin() {
  try {
    return isLocalReplicaHost(window.location.hostname);
  } catch {
    return false;
  }
}
