#!/usr/bin/env node
// tests/frontend_security.test.mjs — static-analysis guards for the frontend
// security fixes tracked in docs/issue-triage-2026-08.md §1.1, §1.2 and the
// CSP/SRI items.
//
// WHY STATIC. Every property below is a property of the SOURCE, not of a
// running page: "the certificate check is passed a tagged principal", "the root
// key is never fetched from a remote host", "the delegation relay cannot be
// pointed at another origin", "no third-party script is loaded", "the shipped
// asset config actually sets a CSP". Each of these was, at some point, wrong in
// a way that produced no runtime error at all — the certificate check threw on
// every call for its entire life and the page still painted green. A test that
// needs a replica, a browser and a signed-in user to notice that is a test that
// will not be run. These run in ~20ms with plain `node`, no deps, no network.
//
// Usage:
//   node tests/frontend_security.test.mjs           # check the working tree
//   node tests/frontend_security.test.mjs <root>    # check another checkout
//
// The second form is how the "fails before the fix" half of the contract is
// demonstrated: materialise an older tree (git worktree, or `git show`) and
// point this at it.

import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { join, dirname, resolve } from "node:path";
import { stripJsComments } from "./_lib.mjs";

const ROOT = process.argv[2]
  ? resolve(process.argv[2])
  : resolve(dirname(fileURLToPath(import.meta.url)), "..");

let passed = 0;
let failed = 0;

function ok(name) { passed++; console.log(`✓ ${name}`); }
function bad(name, detail) {
  failed++;
  console.log(`✗ ${name}`);
  if (detail) console.log(`    ${String(detail).split("\n").join("\n    ")}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }

const path = (p) => join(ROOT, p);
function read(p) {
  const f = path(p);
  if (!existsSync(f)) return null;
  return readFileSync(f, "utf8");
}

// A file that is supposed to exist but doesn't is a failure, not a crash —
// otherwise one moved file silently skips a whole section of this suite.
function must(p) {
  const s = read(p);
  if (s === null) bad(`${p} exists`, `not found under ${ROOT}`);
  return s;
}

const stripHtmlComments = (src) => src.replace(/<!--[\s\S]*?-->/g, "");

// ── JSON5-lite: strip comments + trailing commas, then JSON.parse ────
// String-aware, because the CSP value in .ic-assets.json5 contains "http://".
function parseJson5(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'") {
      const quote = c;
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { i += 2; while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++; i += 2; continue; }
    out += c; i++;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

// The exact bytes of the one inline script in ai-connect.html — what a CSP
// 'sha256-…' source expression is computed over.
function inlineScriptOf(html) {
  const open = "<" + "script>";
  const close = "</" + "script>";
  const a = html.indexOf(open);
  const b = html.lastIndexOf(close);
  if (a < 0 || b < a) return null;
  return html.slice(a + open.length, b);
}
const sriHash = (s) => "sha256-" + createHash("sha256").update(s, "utf8").digest("base64");

console.log(`frontend security guards — ${ROOT}\n`);

// ════════════════════════════════════════════════════════════════════
// A. The ledger verifier's certificate check actually runs, and fails closed
// ════════════════════════════════════════════════════════════════════
console.log("A. ledger.js — IC certificate validation");
{
  const raw = must("src/frontend/src/ledger.js");
  const src = raw === null ? null : stripJsComments(raw);
  if (src) {
    // The SDK dispatches on the object SHAPE. A bare Principal takes an
    // unreachable branch and throws, which the catch downgraded to {ok:null} —
    // so the check never ran, in any environment, for its whole life.
    check("Certificate.create is passed a TAGGED principal ({ canisterId: … })",
      /principal:\s*\{\s*canisterId\s*:/.test(src),
      "expected `principal: { canisterId: cid }` — see scripts/verify_ledger.mjs:430-435");

    check("no bare `principal: <Principal>` is passed",
      !/principal:\s*cid\s*,/.test(src),
      "a bare Principal makes Certificate.create throw UNREACHABLE_ERROR");

    // With time verification off, a replayed OLD certificate over an OLD head
    // verifies — which is exactly how a truncated tape stays invisible.
    const timeLines = src.split("\n").filter((l) => l.includes("disableTimeVerification"));
    check("disableTimeVerification is not set unconditionally",
      timeLines.length > 0 && timeLines.every((l) => /local|isLocalReplica/.test(l)),
      timeLines.length
        ? `unguarded occurrence(s):\n${timeLines.filter((l) => !/local|isLocalReplica/.test(l)).join("\n")}`
        : "expected the flag, gated on a local-replica check");

    check("locality comes from the shared exact-match predicate",
      /import\s*\{[^}]*isLocalReplicaOrigin[^}]*\}\s*from\s*["']\.\/host\.js["']/.test(src),
      "expected `import { isLocalReplicaOrigin } from \"./host.js\"`");

    // FAIL CLOSED: ok===null (the swallowed-throw case) must not paint green.
    check("green `lg-ok` is never set unconditionally",
      !/className\s*=\s*["']lg-verify-out lg-ok["']/.test(src),
      "the verified state was painted regardless of the certificate result");

    check("green `lg-ok` is gated on a true certificate result",
      /certOk\s*\?\s*["']lg-verify-out lg-ok["']/.test(src),
      "expected `res.certOk ? \"lg-verify-out lg-ok\" : …`");

    check("verifyChainClient reports certOk as a hard boolean",
      /certOk:\s*certCheck\.ok\s*===\s*true/.test(src),
      "callers must not have to interpret null themselves");

    check("the unverified state says so in words",
      /certificate NOT verified/i.test(src) && /self-consistent/i.test(src),
      "expected a distinct \"chain self-consistent, certificate NOT verified\" state");
  }
}

// ════════════════════════════════════════════════════════════════════
// B. The root key never comes from the host being verified
// ════════════════════════════════════════════════════════════════════
console.log("\nB. main.js / host.js — root key provenance");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    const calls = [...src.matchAll(/fetchRootKey\s*\(/g)];
    check("fetchRootKey is called at most once", calls.length <= 1,
      `${calls.length} call sites — each needs its own guard`);

    for (const m of calls) {
      // The guard must be adjacent to the call, not somewhere up the file.
      const before = src.slice(Math.max(0, m.index - 300), m.index);
      check("fetchRootKey is guarded by a local-host check",
        /if\s*\(\s*isLocalReplicaOrigin\s*\(\s*\)\s*\)/.test(before),
        "on mainnet the IC gateway proxies /api/v2/status, so an unguarded "
        + "fetchRootKey takes the certificate anchor from the party being checked");
    }
    if (calls.length === 0) ok("fetchRootKey is guarded by a local-host check (no call sites)");

    check("main.js imports the shared local-host predicate",
      /import\s*\{[^}]*isLocalReplicaOrigin[^}]*\}\s*from\s*["']\.\/host\.js["']/.test(src));
  }

  const rawHost = must("src/frontend/src/host.js");
  const host = rawHost === null ? null : stripJsComments(rawHost);
  if (host) {
    // Exact hostname match, so `localhost.evil.example` is NOT local.
    for (const h of ["localhost", "127.0.0.1", "::1"]) {
      check(`host.js matches ${h} by equality`,
        new RegExp(`===\\s*["']${h.replace(/\./g, "\\.")}["']`).test(host));
    }
    check("host.js allows the reserved .localhost TLD by suffix",
      /endsWith\(\s*["']\.localhost["']\s*\)/.test(host));
    check("host.js never substring-matches the hostname",
      !/\.includes\(|\.indexOf\(|\.match\(/.test(host),
      "substring matching makes `localhost.evil.example` look local");
    check("host.js reads a hostname, never a whole URL",
      !/location\.href|location\.origin/.test(host));
  }
}

// ════════════════════════════════════════════════════════════════════
// C. ai-connect.html — the delegation handshake
// ════════════════════════════════════════════════════════════════════
console.log("\nC. ai-connect.html — II delegation handshake");
let aiScript = null;
{
  const html = must("src/frontend/public/ai-connect.html");
  if (html) {
    aiScript = inlineScriptOf(html);
    check("the handshake script is present and extractable", aiScript !== null);
  }
  // Patterns are matched against the script with comments removed; the CSP
  // hash in section E is computed over the RAW bytes, which is what ships.
  const s = aiScript === null ? "" : stripJsComments(aiScript);

  // C1 — the callback authority. `1@attacker.example.com` as the port turns
  // "http://127.0.0.1:" + PORT + "/callback" into an attacker-hosted URL, and
  // the SIGNED delegation is POSTed there.
  check("the callback port is validated as a decimal integer",
    /\/\^\[0-9\]\{1,5\}\$\//.test(s),
    "expected a /^[0-9]{1,5}$/ test on the port fragment param");
  check("the callback port is range-checked to 1-65535",
    /65535/.test(s) && />=\s*1\b/.test(s));
  check("the callback URL is built with new URL(), not concatenation",
    /new URL\(\s*["']http:\/\/127\.0\.0\.1\//.test(s));
  check("no string-concatenated callback authority survives",
    !/["']http:\/\/127\.0\.0\.1:["']\s*\+/.test(s),
    "concatenating an unvalidated port into the authority is the whole bug");
  check("an invalid port is refused visibly rather than defaulted away",
    /CALLBACK\s*===\s*null/.test(s) && /refuse\(/.test(s));
  check("the outbound destination is re-checked at the send site",
    /dest\.hostname\s*!==\s*["']127\.0\.0\.1["']/.test(s),
    "nothing validated where the signed delegation actually leaves the page");

  // C2 — displayed lifetime must be the minted lifetime.
  check("the display-only ttl_hours param is gone",
    !/ttl_hours/.test(s),
    "the lifetime shown and the lifetime minted were two different inputs");
  check("the displayed TTL is derived from the minted TTL",
    /getElementById\(["']ttl["']\)\.textContent\s*=[^;]*TTL_NS/.test(s));
  check("the minted TTL is clamped to a ceiling",
    /TTL_MAX_NS/.test(s) && /TTL_MAX_NS\s*:\s*requested|requested\s*>\s*TTL_MAX_NS/.test(s));
  check("the ceiling is 8 hours",
    /8n\s*\*\s*60n\s*\*\s*60n\s*\*\s*1000000000n/.test(s));
  check("the TTL actually sent is the clamped value",
    /maxTimeToLive:\s*TTL_NS\b/.test(s));

  // C3 — scope. No `targets` ⇒ valid for every canister on the IC.
  check("the authorize-client request carries targets",
    /targets:\s*\[\s*BACKEND_ID\s*\]/.test(s),
    "without targets the delegation is valid for EVERY canister");
  check("the target id comes from the ic:canister-id meta tag",
    /meta\[name=["']ic:canister-id["']\]/.test(s));
  check("an unresolved/placeholder canister id refuses to mint",
    /BACKEND_OK/.test(s) && /!BACKEND_OK/.test(s));

  // C4 — both ends of the relay pinned.
  check("the inbound postMessage checks event.source",
    /event\.source\s*!==\s*ii/.test(s),
    "the origin check alone lets any window on that origin drive the handshake");
  check("the inbound postMessage still checks event.origin",
    /event\.origin\s*!==\s*II_ORIGIN/.test(s));
}

// ════════════════════════════════════════════════════════════════════
// D. Third-party script + Content-Security-Policy
// ════════════════════════════════════════════════════════════════════
console.log("\nD. third-party script + CSP");
{
  const rawIndex = must("src/frontend/index.html");
  const html = rawIndex === null ? null : stripHtmlComments(rawIndex);
  if (html) {
    check("index.html references no CDN script host",
      !/unpkg\.com|cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com/.test(html));
    check("index.html loads no absolute-URL script",
      !/<script[^>]*\ssrc\s*=\s*["']https?:/i.test(html));
    check("index.html has no inline script block",
      !/<script(?![^>]*\ssrc=)[^>]*>[\s\S]*?<\/script>/i.test(html),
      "an inline block would need 'unsafe-inline' or a hash under the CSP");
  }

  const pkg = must("package.json");
  const lock = read("package-lock.json");
  if (pkg) {
    const j = JSON.parse(pkg);
    check("lightweight-charts is a declared dependency",
      !!(j.dependencies && j.dependencies["lightweight-charts"]),
      "it was loaded from a CDN and appeared in neither package.json nor the lockfile");
  }
  check("lightweight-charts is pinned in package-lock.json",
    !!lock && /"node_modules\/lightweight-charts"/.test(lock));

  const rawMainD = read("src/frontend/src/main.js");
  const main = rawMainD === null ? null : stripJsComments(rawMainD);
  if (main) {
    check("main.js imports the charting library",
      /import\s*\{[^}]*createChart[^}]*\}\s*from\s*["']lightweight-charts["']/.test(main));
    check("main.js no longer reads the library off `window`",
      !/window\.LightweightCharts/.test(main));

    // `standard` forbids inline event-handler attributes. These 8 used to be
    // `onerror="this.style.display='none'"` on token-logo <img>s.
    const inline = [...main.matchAll(/\son[a-z]+\s*=\s*["'][^"']*["']/gi)]
      .filter((m) => !/\son(ly|e)\b/i.test(m[0]));
    check("main.js emits no inline event-handler attributes",
      inline.length === 0,
      inline.map((m) => m[0].trim()).join("\n"));
    check("main.js contains no `onerror=` attribute",
      !main.includes("onerror=\""),
      "converted to a capture-phase addEventListener(\"error\", …)");
    check("the replacement error handler is wired with addEventListener",
      /addEventListener\(\s*["']error["'][\s\S]{0,200}?,\s*true\s*\)/.test(main),
      "`error` does not bubble — the listener must be in the capture phase");
  }
}

// ════════════════════════════════════════════════════════════════════
// E. The asset config that actually ships
// ════════════════════════════════════════════════════════════════════
console.log("\nE. .ic-assets.json5 — the file that ships");
{
  check("the dead sibling src/frontend/.ic-assets.json5 is gone",
    !existsSync(path("src/frontend/.ic-assets.json5")),
    "vite copies only publicDir; rules at the vite root silently do nothing");

  const raw = must("src/frontend/public/.ic-assets.json5");
  if (raw) {
    let cfg = null;
    try { cfg = parseJson5(raw); ok("public/.ic-assets.json5 parses"); }
    catch (e) { bad("public/.ic-assets.json5 parses", e.message); }

    if (Array.isArray(cfg)) {
      const catchAll = cfg.filter((r) => r && r.match === "**/*");
      check("a catch-all rule sets a security_policy",
        catchAll.some((r) => typeof r.security_policy === "string" && r.security_policy.length > 0),
        "with no security_policy the deployed app serves no CSP at all");

      const ai = cfg.find((r) => r && r.match === "ai-connect.html");
      const csp = ai && ai.headers && ai.headers["Content-Security-Policy"];
      check("ai-connect.html carries its own Content-Security-Policy", !!csp);
      if (csp) {
        const m = /'(sha256-[A-Za-z0-9+/=]+)'/.exec(csp);
        check("that policy pins the inline script by hash", !!m,
          "the page has an inline script; 'unsafe-inline' would defeat the point");
        if (m && aiScript !== null) {
          const want = sriHash(aiScript);
          check("the pinned hash matches the script as committed",
            m[1] === want,
            `config has ${m[1]}\nscript hashes to ${want}\n`
            + "→ paste the second value into src/frontend/public/.ic-assets.json5");
        }
        check("the policy keeps frame-ancestors 'none'", /frame-ancestors\s+'none'/.test(csp));
        check("the policy allows the loopback callback",
          /connect-src[^;]*127\.0\.0\.1/.test(csp));
        // `standard` includes upgrade-insecure-requests, which would rewrite the
        // http://127.0.0.1 callback to https and break every sign-in.
        check("the policy does not upgrade the loopback callback to https",
          !/upgrade-insecure-requests/.test(csp));
      }
    }
  }
}

// ── Summary ─────────────────────────────────────────────────────────
console.log("");
if (failed === 0) {
  console.log(`PASS — ${passed} assertions`);
  process.exit(0);
} else {
  console.log(`FAIL — ${failed} of ${passed + failed} assertions failed`);
  process.exit(1);
}
