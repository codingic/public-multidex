// ── Self-updating clients ────────────────────────────────────────────
// Polls the app's OWN origin for /version.json (emitted at build, served by
// the asset canister) and gets stale tabs onto the newest deployed build.
//
// Why the FRONTEND origin is the trigger, not the backend wasm: frontend-only
// deploys are the common case (the assets and the backend ship separately),
// and a backend-carried version cannot see them — while a backend-only
// upgrade needs no client refresh at all (the interface discipline is
// additive). The backend still carries its own APP_VERSION (getAppVersion /
// getCanisterInfo.appVersion) as a diagnostic, so a mixed deploy is visible,
// but refresh decisions key on what this origin actually serves.
//
// Behaviour, in escalating order of intrusiveness:
//   1. HIDDEN tab + newer version  → reload silently after a jittered delay
//      (8–30s — no thundering herd, and returning to the tab cancels the
//      silent path in favour of the banner). A reload never loses on-chain
//      state — orders/positions/balances live in the canister and the hash
//      route survives — only unsent form text, which a hidden tab has none
//      of anyone is touching.
//   2. VISIBLE tab + newer version → a dismissable banner with a Refresh
//      button. Dismissing snoozes it (it returns on a later poll); it never
//      reloads under the user's hands.
//   3. version.json may carry `minSupported` (set by hand for a BREAKING
//      release): a client older than that shows a blocking modal with a
//      countdown and reloads when it expires — for the rare case where the
//      running bundle can no longer talk to the backend correctly.
//
// Guards: a sessionStorage marker prevents reload loops (if the origin still
// serves a version we already reloaded for — e.g. an aggressive cache — the
// banner shows instead of looping); a missing/unparseable version.json is a
// silent no-op (the vite dev server has none); polls ride cache: "no-store"
// so the browser HTTP cache — the very thing that strands clients — is
// bypassed for the check itself.

const POLL_MS         = 60_000;
const SNOOZE_MS       = 10 * 60_000;
const COUNTDOWN_S     = 60;
const RELOADED_KEY    = (v) => `mdx.updateReloaded.${v}`;

let _running = "";           // the version baked into THIS bundle
let _snoozedUntil = 0;
let _hiddenTimer = null;
let _bannerEl = null;
let _modalEl = null;

// "1.51.0" → [1, 51, 0]; missing parts compare as 0.
function cmpVersions(a, b) {
  const pa = String(a).split(".").map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d !== 0) return d;
  }
  return 0;
}

function reloadNow(target) {
  try { sessionStorage.setItem(RELOADED_KEY(target), "1"); } catch {}
  location.reload();
}

function dismissBanner() {
  _snoozedUntil = Date.now() + SNOOZE_MS;
  if (_bannerEl) { _bannerEl.remove(); _bannerEl = null; }
}

function showBanner(target) {
  if (_bannerEl || _modalEl) return;
  if (Date.now() < _snoozedUntil) return;
  const el = document.createElement("div");
  el.className = "update-banner";
  el.innerHTML =
    `<span>A new version of MULTI/DEX is available (v${esc(target)}).</span>` +
    `<button type="button" class="btn btn-primary btn-sm update-banner-go">Refresh</button>` +
    `<button type="button" class="update-banner-x" aria-label="Dismiss">✕</button>`;
  el.querySelector(".update-banner-go").addEventListener("click", () => reloadNow(target));
  el.querySelector(".update-banner-x").addEventListener("click", dismissBanner);
  document.body.appendChild(el);
  _bannerEl = el;
}

function showMandatoryModal(target) {
  if (_modalEl) return;
  if (_bannerEl) { _bannerEl.remove(); _bannerEl = null; }
  const el = document.createElement("div");
  el.className = "modal update-modal";
  el.innerHTML =
    `<div class="modal-backdrop"></div>` +
    `<div class="modal-content update-modal-content">` +
    `<h3>Update required</h3>` +
    `<p>This version of the app is too old to keep working correctly with the
     exchange. It will refresh automatically in
     <b class="update-countdown">${COUNTDOWN_S}</b>s — or refresh now.</p>` +
    `<div class="modal-buttons"><button type="button" class="btn btn-primary update-modal-go">Refresh now</button></div>` +
    `</div>`;
  el.querySelector(".update-modal-go").addEventListener("click", () => reloadNow(target));
  document.body.appendChild(el);
  _modalEl = el;
  let left = COUNTDOWN_S;
  const tick = setInterval(() => {
    left -= 1;
    const c = el.querySelector(".update-countdown");
    if (c) c.textContent = String(left);
    if (left <= 0) { clearInterval(tick); reloadNow(target); }
  }, 1000);
}

function esc(s) {
  return String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
}

function onNewVersion(target, mandatory) {
  const alreadyTried = (() => {
    try { return sessionStorage.getItem(RELOADED_KEY(target)) === "1"; } catch { return false; }
  })();
  if (mandatory && !alreadyTried) { showMandatoryModal(target); return; }
  if (alreadyTried) { showBanner(target); return; }   // loop guard: never auto-reload twice
  if (document.hidden) {
    // Silent path — jittered so a fleet of background tabs doesn't stampede
    // the gateway, cancelled if the user comes back mid-wait.
    if (_hiddenTimer) return;
    _hiddenTimer = setTimeout(() => {
      _hiddenTimer = null;
      if (document.hidden) reloadNow(target); else showBanner(target);
    }, 8_000 + Math.random() * 22_000);
  } else {
    showBanner(target);
  }
}

async function checkOnce() {
  let info;
  try {
    const r = await fetch("/version.json", { cache: "no-store" });
    if (!r.ok) return;               // vite dev / very old deploys: no file — no-op
    info = await r.json();
  } catch { return; }
  const target = info && info.version;
  if (!target || typeof target !== "string") return;
  if (cmpVersions(target, _running) <= 0) {
    // Up to date (or origin serves older — a rollback: leave the newer
    // running bundle alone; it reloaded once via the loop guard if it tried).
    if (_bannerEl) { _bannerEl.remove(); _bannerEl = null; }
    return;
  }
  const mandatory = !!(info.minSupported && cmpVersions(_running, info.minSupported) < 0);
  onNewVersion(target, mandatory);
}

export function startUpdateCheck(runningVersion) {
  _running = String(runningVersion || "");
  if (!_running) return;
  checkOnce();
  setInterval(checkOnce, POLL_MS);
  document.addEventListener("visibilitychange", () => {
    if (_hiddenTimer && !document.hidden) { clearTimeout(_hiddenTimer); _hiddenTimer = null; }
    if (!document.hidden) checkOnce();   // waking a laptop / returning to the tab
  });
}
