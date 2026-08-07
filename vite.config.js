import { defineConfig } from "vite";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";

// Cloud-engine flag, baked in at build time from the VITE_CLOUD_ENGINE env var
// (set by scripts/deploy.sh when deploying to a cloud engine). On a cloud engine
// the engine holds the cycles balance and pays for operation, so the canister's
// own cycles read ~0 — the app's "low/out of cycles" warning would be a false
// alarm. When true, the frontend suppresses that warning (memory warnings stay).
const cloudEngineRaw = (process.env.VITE_CLOUD_ENGINE || "").trim().toLowerCase();
const CLOUD_ENGINE = cloudEngineRaw === "true" || cloudEngineRaw === "1" || cloudEngineRaw === "yes";

// The app version, single-sourced from package.json. Baked into the bundle as
// __APP_VERSION__ (the footer badge and the update checker read it) and
// emitted as /version.json by the plugin below, which deployed clients poll
// to notice a newer build and refresh themselves (src/frontend/src/
// update-check.js). Release bumps: package.json here and APP_VERSION in
// src/backend/main.mo (kept in step by hand; the backend one is diagnostic).
const APP_VERSION = JSON.parse(readFileSync(fileURLToPath(new URL("./package.json", import.meta.url)), "utf8")).version;

// Emit /version.json alongside the build: { version, builtAt }. minSupported
// may be added by hand for a BREAKING release — clients older than it show a
// blocking countdown instead of a dismissable banner (see update-check.js).
//
// Also stamps the footer badge INTO the built index.html. The span used to be
// empty markup filled by main.js mid-init, so every refresh showed a blank
// badge until the bundle booted — indefinitely, when anything ahead of the
// stamp hiccuped (seen live 2026-08-07). Build-injected text is visible from
// the first paint and can't drift: it comes from the same APP_VERSION as the
// bundle's __APP_VERSION__ (the runtime re-stamp writes identical text).
function emitVersionJson() {
  const badge = `VERSION ${APP_VERSION.replace(/\.0$/, "")}`; // same text main.js stamps
  return {
    name: "emit-version-json",
    apply: "build",
    transformIndexHtml(html) {
      const needle = '<span class="app-version"></span>';
      if (!html.includes(needle)) {
        // The empty span is the contract with main.js's re-stamp — if the
        // markup drifts, fail the build rather than ship a blank badge again.
        throw new Error("[version badge] index.html no longer carries the empty .app-version span");
      }
      return html.replace(needle, `<span class="app-version">${badge}</span>`);
    },
    closeBundle() {
      const dir = fileURLToPath(new URL("./dist", import.meta.url));
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      writeFileSync(`${dir}/version.json`,
        JSON.stringify({ version: APP_VERSION, builtAt: new Date().toISOString() }) + "\n");
      console.log(`[version.json] emitted v${APP_VERSION}`);
    },
  };
}

// The App Connect bridge page (src/frontend/public/ai-connect.html) ships as a
// TEMPLATE: its ic:canister-id meta holds the literal placeholder below. A
// connector reads the RAW served HTML (it does NOT run the page's JS), so the
// built markup must carry the real backend id. This plugin substitutes it for
// the build's target network.
const AI_CONNECT_PLACEHOLDER = "place-deployed-canister-id-here";

// Resolve a deployed canister id for the build's target network:
//   1. AI_CONNECT_<NAME>_ID env — set by scripts/deploy.sh for cloud / subnet
//      deploys (ids differ per network, so they are fed in at deploy time).
//   2. .icp/cache/mappings/local.ids.json .<name> — the local replica (dev).
function resolveCanisterId(name) {
  const envName = `AI_CONNECT_${name.toUpperCase()}_ID`;
  const env = (process.env[envName] || "").trim();
  if (env) {
    if (/^[a-z0-9-]+$/.test(env)) return env;
    console.warn(`[ai-connect] ignoring malformed ${envName}: ${env}`);
    return "";
  }
  try {
    const map = fileURLToPath(new URL("./.icp/cache/mappings/local.ids.json", import.meta.url));
    if (existsSync(map)) {
      const id = (JSON.parse(readFileSync(map, "utf8"))[name] || "").trim();
      if (/^[a-z0-9-]+$/.test(id)) return id;
    }
  } catch { /* fall through to the loud warning below */ }
  return "";
}
const resolveBackendCanisterId = () => resolveCanisterId("backend");

// Replace the placeholder in the built ai-connect.html with the real backend id.
// Fails LOUD (leaves the placeholder) when the id can't be resolved, so a
// misconfigured deploy is obvious rather than silently shipping a dead page.
function bakeAiConnectCanisterId() {
  return {
    name: "bake-ai-connect-canister-id",
    apply: "build",
    closeBundle() {
      const file = fileURLToPath(new URL("./dist/ai-connect.html", import.meta.url));
      if (!existsSync(file)) return;
      const html = readFileSync(file, "utf8");
      if (!html.includes(AI_CONNECT_PLACEHOLDER)) return; // already substituted
      const id = resolveBackendCanisterId();
      if (!id) {
        console.warn(
          `[ai-connect] ⚠ '${AI_CONNECT_PLACEHOLDER}' left UNSUBSTITUTED in dist/ai-connect.html — ` +
          "set AI_CONNECT_BACKEND_ID (cloud/mainnet) or deploy the backend to the local replica first. " +
          "App Connect will report canister_not_found until this is fixed.",
        );
        return;
      }
      writeFileSync(file, html.split(AI_CONNECT_PLACEHOLDER).join(id));
      console.log(`[ai-connect] set backend canister id ${id} in dist/ai-connect.html`);
    },
  };
}

// Emit /.well-known/ic-app.json — a machine-readable manifest of EVERY
// canister in the app with its role, so agent tooling that discovers apps by
// domain can find the backend (the App Connect meta tag in ai-connect.html
// only names the single main backend; this covers the multi-canister case —
// the format is the MCP-connector proposal for that spec gap, understood by
// IMCP2 today). Same deploy-time id rules as the meta tag above, and the
// dot-directory must be exempted from the asset sync's dotfile skip — see
// src/frontend/public/.ic-assets.json5.
function emitWellKnownManifest() {
  return {
    name: "emit-well-known-ic-app-manifest",
    apply: "build",
    closeBundle() {
      const backend = resolveCanisterId("backend");
      if (!backend) {
        console.warn(
          "[ic-app.json] ⚠ backend canister id unresolved — /.well-known/ic-app.json NOT emitted. " +
          "Set AI_CONNECT_BACKEND_ID (cloud/subnet) or deploy the backend to the local replica first.",
        );
        return;
      }
      const canisters = [
        { id: backend, role: "backend", description: "MULTI/DEX API — call getApiDoc() first" },
      ];
      const bridge = resolveCanisterId("bridge");
      if (bridge) canisters.push({ id: bridge, role: "bridge" });
      const frontend = resolveCanisterId("frontend");
      if (frontend) canisters.push({ id: frontend, role: "frontend" });
      const dir = fileURLToPath(new URL("./dist/.well-known", import.meta.url));
      mkdirSync(dir, { recursive: true });
      writeFileSync(`${dir}/ic-app.json`, JSON.stringify({ canisters }, null, 2) + "\n");
      console.log(`[ic-app.json] emitted /.well-known/ic-app.json (${canisters.map((c) => c.role).join(", ")})`);
    },
  };
}

export default defineConfig({
  root: "src/frontend",
  plugins: [bakeAiConnectCanisterId(), emitWellKnownManifest(), emitVersionJson()],
  define: {
    __CLOUD_ENGINE__: JSON.stringify(CLOUD_ENGINE),
    __APP_VERSION__: JSON.stringify(APP_VERSION),
  },
  build: {
    outDir: "../../dist",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": "http://localhost:8000",
    },
  },
});
