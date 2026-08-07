#!/bin/bash
# tests/test_deploy_hygiene.sh
#
# STATIC regression for the operator-machine defects in
# docs/issue-triage-2026-08.md §3 and §4.1. Every one of these was a real
# incident or a live vulnerability, and every one is invisible to the
# integration suite because it lives in the DEPLOY SCRIPTS, not the canister.
# So this test reads source, not state.
#
# NO REPLICA REQUIRED — it never calls a canister. That is deliberate: these
# are exactly the checks you want still working when the exchange is down.
#
# What it pins, and why each one is here:
#
#   1. awk PROGRAM-TEXT INJECTION (#10.1). deploy.sh built an awk program by
#      string interpolation, splicing in field 2 of a fixed-name file under
#      /tmp. awk has system(). Because /tmp is sticky (1777), a file planted
#      there by another local user cannot be removed or overwritten by our own
#      `rm -f` — so it is a PERSISTENT plant, not a race. Values belong in
#      `-v` bindings, where they are data and can never be parsed as code.
#
#   2. FIXED-NAME /tmp PATHS. Same root cause as (1): the plantable file. The
#      deploy scripts now use .run/ (repo-local, operator-owned, gitignored)
#      via scripts/lib/runfiles.sh.
#
#   3. BARE PATTERN KILLS (#10.2). A pattern cannot tell a local simulator
#      from one driving multidex.ai — the target used to live only in IC_ENV,
#      and environment assignments are not part of argv. This killed the LIVE
#      fleet on 2026-07-23, 2026-07-28 and 2026-08-01. Stops belong to the
#      PID-file architecture in scripts/lib/{targets,bots}.sh, which kills by
#      ancestry from a PID recorded at launch. Killing one's OWN children by
#      parent pid is fine — that is ancestry, not a pattern.
#
#   4. UNKNOWN DEPLOY TARGET (#10.5). deploy_to_engine.sh execs
#      `deploy.sh engine`, but deploy.sh's vocabulary was local|cloud|subnet,
#      so `engine` fell through to a plain passthrough that SKIPS
#      apply_anti_sybil_settings — the step that re-stamps production
#      frontend_origins, whose absence took multidex.ai sign-in down on
#      2026-07-11. An unrecognised target must now be a HARD ERROR.
#
#   5. lint-ratchet's DEAD TYPE-CHECK (§4.1). It ran moc without the project's
#      build flags, and detected failure with a pattern moc never emits, so it
#      matched nothing and reported success unconditionally.
#
#   6. UNPINNED FRONTEND BUILD (#10.4). The build that produces the assets
#      served from multidex.ai must install exactly what the lockfile pins.
#
#   7. BRIDGE POSTURE (§2.15). The Bridge had no posture concept at all, and
#      icp.yaml wires this same stub into BOTH production-facing targets.
#
# Uses _lib.sh's _ok/_fail counters but its own matchers and summary. NOT
# _lib.sh's assert_contains: that helper strips underscores from the haystack
# (a Candid number-formatting quirk) and treats the needle as a REGEX, so a
# source needle like IS_PRODUCTION or '*.mo' could never match correctly.

source "$(dirname "$0")/_lib.sh"

ROOT="$SCRIPT_DIR"
cd "$ROOT" || exit 1

echo "── test_deploy_hygiene ──"

# ── Literal source matchers ───────────────────────────────────────
src_has() {   # src_has <name> <haystack> <literal needle>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then _ok "$1"
  else _fail "$1 — expected to find: $3"; fi
}
src_lacks() { # src_lacks <name> <haystack> <literal needle>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then
    _fail "$1 — found banned text: $3"
    printf '%s\n' "$2" | grep -nF -- "$3" | head -5 | sed 's/^/      /' >&2
  else _ok "$1"; fi
}

# Strip shell/YAML comments before scanning, so a line DOCUMENTING a banned
# pattern (several of them deliberately quote the old bug, and so does this
# file) is not itself a hit.
uncommented() { sed 's/#.*//' "$1"; }
# Same idea for Motoko, on stdin: the comment inside claim() that explains why
# ledgerOf is deliberately NOT called must not read as a call to it.
mo_code() { sed 's://.*::'; }

# Extract one Motoko function body by brace depth from its signature line.
# A sed line-range cannot do this: the closing brace of `claim` is at the same
# indent as several later declarations, so a range over-runs into the next
# function and the assertions silently test the wrong code.
mo_func() {   # mo_func <file> <signature substring>
  # `seen` is load-bearing: a Motoko signature may wrap before its opening
  # brace (a multi-line return type is the usual reason), and without it the
  # depth test fires on the signature line itself and extraction stops after
  # ONE line. That fails loudly for src_has but passes VACUOUSLY for src_lacks,
  # which is the dangerous direction — so don't start counting down until an
  # opening brace has actually been seen.
  awk -v sig="$2" '
    !on && index($0, sig) { on = 1 }
    on {
      print
      line = $0
      o = gsub(/\{/, "&", line)
      c = gsub(/\}/, "&", line)
      depth += o - c
      if (o > 0) { seen = 1 }
      if (seen && depth <= 0) exit
    }
  ' "$1"
}

# The scripts that run on a deploy path. Explicit rather than globbed: a new
# script must be added here CONSCIOUSLY, which is the point of a ratchet.
DEPLOY_SCRIPTS="
scripts/deploy.sh
scripts/deploy_to_local.sh
scripts/deploy_to_engine.sh
scripts/deploy_to_subnet.sh
scripts/cold_start.sh
scripts/play_start.sh
scripts/seed.sh
scripts/inject_history.sh
"

# ── 1. No awk program-text interpolation anywhere in scripts/ ─────
# A double-quoted awk program is one a shell variable can be spliced into; a
# single-quoted program with -v bindings cannot be. This bans the SHAPE, not
# just today's instances.
AWK_HITS=""
for f in scripts/*.sh scripts/lib/*.sh; do
  [ -f "$f" ] || continue
  h=$(uncommented "$f" | grep -nE 'awk +"' || true)
  [ -n "$h" ] && AWK_HITS="$AWK_HITS $f:$h"
done
assert_eq "no awk program-text interpolation in scripts/" "" "$(printf '%s' "$AWK_HITS" | tr -d '[:space:]')"

# The site that was exploitable. Assert the FIX is present, not merely that
# the old shape is gone.
SEED_PX=$(sed -n '/^seed_px()/,/^}/p' scripts/deploy.sh)
src_has   "seed_px binds the price with -v (data, not program text)" "$SEED_PX" 'awk -v p='
src_has   "seed_px validates the price against a decimal pattern"    "$SEED_PX" '^[0-9]+(\.[0-9]+)?$'
src_lacks "seed_px has no interpolated awk program"                  "$SEED_PX" 'awk "'

# ── 2. No fixed-name /tmp paths in the deploy scripts ─────────────
TMP_HITS=""
for f in $DEPLOY_SCRIPTS scripts/simulate_trading.sh; do
  [ -f "$f" ] || continue
  h=$(uncommented "$f" | grep -n '/tmp/' || true)
  [ -n "$h" ] && TMP_HITS="$TMP_HITS $f:$h"
done
assert_eq "no fixed /tmp paths in the deploy scripts" "" "$(printf '%s' "$TMP_HITS" | tr -d '[:space:]')"
src_has "runfiles.sh defines the shared price-snapshot path" \
  "$(cat scripts/lib/runfiles.sh)" "MDX_ORACLE_PRICES"

# The writer and every reader must agree on ONE path. If they drift, the
# readers silently fall back to stale hardcoded prices and walk a freshly
# seeded AMM off its real price — a failure play_start.sh already documents.
for f in scripts/inject_history.sh scripts/deploy.sh scripts/play_start.sh \
         scripts/seed.sh scripts/simulate_trading.sh; do
  src_has "$(basename "$f") reads/writes the shared snapshot path" "$(cat "$f")" "MDX_ORACLE_PRICES"
done

# ── 3. No bare pattern kills in any deploy script — or any test ───
# SCOPE EXTENSION beyond $DEPLOY_SCRIPTS: tests/*.sh is scanned too, as a
# GLOB rather than a listed addition. Nine test files carried their own
# `pkill -9 -f simulate_trading.sh` — the exact class recorded above as
# killing the live fleet three times — precisely because this scan read only
# the explicit deploy list, so the ban never reached one directory over.
# Tests are where stop-the-sim lines keep being (re)written, so a NEW test
# must be covered without anyone remembering a list; the conscious-addition
# rule stays for $DEPLOY_SCRIPTS, whose other checks don't apply to tests.
# (The glob includes _lib.sh, run_all.sh and this file: pattern kills appear
# there only in comments — stripped by uncommented() — or as this scan's own
# quoted regex, which does not match itself.)
# The flag class MUST include digits: the tests' variant was `pkill -9 -f`,
# and `[A-Za-z]` alone let the signal flag slip straight past the scan — the
# glob extension without this was verified to still miss all nine files.
PKILL_HITS=""
for f in $DEPLOY_SCRIPTS tests/*.sh; do
  [ -f "$f" ] || continue
  h=$(uncommented "$f" | grep -nE 'pkill +(-[A-Za-z0-9]+ +)*-f' || true)
  [ -n "$h" ] && PKILL_HITS="$PKILL_HITS $f:$h"
done
assert_eq "no bare pattern kill in any deploy or test script" "" "$(printf '%s' "$PKILL_HITS" | tr -d '[:space:]')"

# cold_start.sh is the script that had not been migrated (play_start.sh had).
COLD=$(cat scripts/cold_start.sh)
src_has "cold_start stops bots via the PID-file wrapper"  "$COLD" "stop_bots_local.sh"
src_has "cold_start starts bots via the PID-file wrapper" "$COLD" "start_bots_local.sh"
src_has "cold_start fails fast on an unhandled error"     "$COLD" "set -euo pipefail"

# ── 4. deploy.sh rejects an unknown target, non-zero ──────────────
UNKNOWN_OUT=$(DEPLOY_TARGET="definitely-not-a-target" bash scripts/deploy.sh 2>&1)
UNKNOWN_RC=$?
assert_eq "unknown target exits non-zero" "1" "$UNKNOWN_RC"
src_has "unknown target names the mistake"          "$UNKNOWN_OUT" "Unknown deploy target"
src_has "unknown target lists the real vocabulary"  "$UNKNOWN_OUT" "local | engine | subnet"
# The failure mode being pinned: it must NOT have quietly become a passthrough.
src_lacks "unknown target did not fall through to a passthrough" "$UNKNOWN_OUT" "Plain passthrough"

# `engine` — the exact spelling deploy_to_engine.sh passes — must be a
# recognised keyword, not an unrecognised word that lands in the passthrough.
DEPLOY_SRC=$(cat scripts/deploy.sh)
src_has "deploy.sh accepts the engine keyword"    "$DEPLOY_SRC" "local|cloud|engine|subnet)"
src_has "deploy.sh canonicalises the target"      "$DEPLOY_SRC" "canonical_target()"
src_has "cloud survives as an alias for engine"   "$DEPLOY_SRC" "engine|cloud)"
src_has "deploy.sh routes engine to the remote flow" "$DEPLOY_SRC" '[ "$TARGET" = "engine" ]'
# Vocabulary agreement with the single source of truth for what a target IS.
src_has "targets.sh vocabulary is local|engine|subnet" \
  "$(cat scripts/lib/targets.sh)" "local|engine|subnet)"
src_has "deploy_to_engine.sh passes the canonical name" \
  "$(cat scripts/deploy_to_engine.sh)" '"engine"'

# ── 5. lint-ratchet's type-check gates on exit codes ──────────────
# Scan CODE only: this script's own header, and lint-ratchet's, both quote the
# broken detector on purpose.
LR_CODE=$(uncommented scripts/lint-ratchet.sh)
LR_ALL=$(cat scripts/lint-ratchet.sh)
src_lacks "lint-ratchet no longer detects errors by text pattern" "$LR_CODE" "grep -qE ': error'"
src_has   "lint-ratchet type-checks with the real build flags"    "$LR_CODE" "--default-persistent-actors"
src_has   "lint-ratchet passes --implicit-package=core"           "$LR_CODE" "--implicit-package=core"
src_has   "lint-ratchet gates the backend check on moc's exit code" "$LR_CODE" 'TYPE_RC'
src_has   "lint-ratchet gates the test check on moc's exit code"  "$LR_CODE" 'if ! T_OUT='
src_has   "lint-ratchet type-checks tests/*.mo as well"           "$LR_CODE" "find tests -name"
src_has   "lint-ratchet records why the gate was dead"            "$LR_ALL"  "unconditionally"

# Behavioural proof that a moc error IS detectable this way — and that the old
# text detector would have missed it. Runs moc directly with the gate's flags
# so it stays fast and does not depend on the rest of the ratchet being green.
# Skip cleanly when the toolchain isn't usable — `mops toolchain bin moc` can
# print a path that doesn't execute, so probe the binary rather than trusting
# the string (lint-ratchet skips on the same principle).
MOC_BIN=$(mops toolchain bin moc 2>/dev/null || true)
MOC_SRCS=$(mops sources 2>/dev/null || true)
if [ -n "$MOC_BIN" ] && [ -n "$MOC_SRCS" ] && "$MOC_BIN" --version >/dev/null 2>&1; then
  PROBE_DIR=$(mktemp -d)
  printf 'let x : Nat = "not a Nat";\n' > "$PROBE_DIR/probe.mo"
  PROBE_OUT=$("$MOC_BIN" $MOC_SRCS --default-persistent-actors --implicit-package=core \
              --check "$PROBE_DIR/probe.mo" 2>&1)
  PROBE_RC=$?
  rm -rf "$PROBE_DIR"
  assert_eq "moc --check exits non-zero on a type error" "1" "$PROBE_RC"
  # The premise of the whole finding: moc says "type error", so a detector
  # looking for a bare ": error" matches neither this nor its own noise.
  src_has "moc reports it as a 'type error'" "$PROBE_OUT" "type error"
  if printf '%s\n' "$PROBE_OUT" | grep -qE ': error'; then
    _fail "the old ': error' detector WOULD have matched — the finding's premise is broken"
  else
    _ok "the old ': error' detector matches nothing (why the gate could not fail)"
  fi
else
  echo "  (moc unavailable — skipped the behavioural type-check proof)"
fi

# ── 6. icp.yaml enforces the committed lockfile ───────────────────
YAML_CODE=$(uncommented icp.yaml)
src_has   "icp.yaml builds the frontend from the lockfile" "$YAML_CODE" "npm ci"
src_lacks "icp.yaml does not resolve deps at build time"   "$YAML_CODE" "npm install"

# ── 7. The Bridge has a posture, and it agrees with the DEX ───────
BRIDGE_SRC=$(cat src/bridge/main.mo)
src_has "bridge declares a DeployMode type"  "$BRIDGE_SRC" "public type DeployMode"
src_has "bridge derives a production flag"   "$BRIDGE_SRC" "IS_PRODUCTION"
src_has "bridge exposes its posture"         "$BRIDGE_SRC" "public query func getDeployMode()"
# `transient` is load-bearing: a plain `let` in a persistent actor is
# implicitly STABLE, so an edited literal would be overwritten by the stored
# value on upgrade and the flip would never land.
src_has "bridge posture is transient (re-read on install AND upgrade)" \
  "$BRIDGE_SRC" "transient let DEPLOY_MODE"

BRIDGE_MODE=$(grep -oE 'transient let DEPLOY_MODE : DeployMode = #[a-z]+' src/bridge/main.mo | grep -oE '#[a-z]+$' | tr -d '#')
DEX_MODE=$(grep -oE 'transient let DEPLOY_MODE : DeployMode = #[a-z]+' src/backend/main.mo | grep -oE '#[a-z]+$' | tr -d '#')
assert_eq "bridge default posture is play" "play" "$BRIDGE_MODE"

# NOT a strict equality check against the DEX. A working-tree flip of the DEX
# to #dev is normal and expected — the dev fixtures and seed.sh need it, and
# deploy.sh's own posture gate exempts the local target for exactly that
# reason. Asserting equality here would fail on every ordinary local test
# session, and a test that cries wolf gets ignored.
#
# The invariant that actually matters is one-directional: the Bridge must
# never be MORE PERMISSIVE than the DEX it credits. Concretely — if the DEX is
# value-bearing, a Bridge that still answers its unbacked-credit hooks is the
# §2.15 hole wide open, and nothing in the deploy path would catch it: the
# scripts read the DEX's literal (mdx_assert_posture_for_target, posture_of)
# and never look at the Bridge's.
if [ "$DEX_MODE" = "production" ] && [ "$BRIDGE_MODE" != "production" ]; then
  _fail "DEX is #production but the Bridge is #$BRIDGE_MODE — the stub's unbacked-credit hooks would be live against a value-bearing DEX"
else
  _ok "bridge is not more permissive than the DEX (DEX #$DEX_MODE / bridge #$BRIDGE_MODE)"
fi

# The asset allowlist must be a GATE, not just a declaration: both write paths
# key permanent maps on the caller's Text, and there is no length check.
src_has "bridge has an asset membership test" "$BRIDGE_SRC" "func isSupportedAsset"

CLAIM_FN=$(mo_func src/bridge/main.mo "func claim(asset : Text)")
[ -n "$CLAIM_FN" ] || _fail "could not extract claim() — the extractor needs updating"
src_has "claim validates the asset" "$CLAIM_FN" "isSupportedAsset"
# THE ORDER IS THE BUG. ledgerOf is get-or-CREATE, and returning #err from an
# update method is a normal return rather than a trap — so a Map.add above the
# rejection COMMITS a permanent row for every rejected call.
src_lacks "claim never calls the get-or-create ledgerOf" \
  "$(printf '%s\n' "$CLAIM_FN" | mo_code)" "ledgerOf("
src_has   "claim reads the ledger without creating it"   "$CLAIM_FN" "Map.get(ledgers"

# The dev hooks must refuse on the UNCAPPED posture. #play deliberately KEEPS
# them: devSimulateDeposit is the live on-ramp there, and the DEX's
# playDepositCap — the thing that bounds it — is active on every play-family
# posture (#dev mirrors #play; only #production has no play cap).
SIM_FN=$(mo_func src/bridge/main.mo "func devSimulateDeposit(")
CONF_FN=$(mo_func src/bridge/main.mo "func devConfirmDeposits(")
[ -n "$SIM_FN" ]  || _fail "could not extract devSimulateDeposit()"
[ -n "$CONF_FN" ] || _fail "could not extract devConfirmDeposits()"
src_has "devSimulateDeposit validates the asset first" "$SIM_FN"  "isSupportedAsset"
src_has "devSimulateDeposit refuses on production"     "$SIM_FN"  "requireNotProduction"
src_has "devConfirmDeposits refuses on production"     "$CONF_FN" "IS_PRODUCTION"
src_has "devConfirmDeposits traps (it has no Result channel)" "$CONF_FN" "Runtime.trap"
# Both must remain usable on #play — the committed posture and the live venue.
src_lacks "devSimulateDeposit is not gated to dev only" "$SIM_FN"  "IS_DEV"
src_lacks "devConfirmDeposits is not gated to dev only" "$CONF_FN" "IS_DEV"

# The liquidation sweep's retry pacing (Menese #12.1). This is a STRUCTURAL
# property no live query can observe: you would have to wedge the batch on a
# real replica to see the difference, and by then it is burning cycles. The
# hazard is specific — _lastLiqNs is stamped only on COMPLETION (correct: it is
# the health signal), so gating the heartbeat's dispatch on it means a trapping
# batch freezes the stamp, leaves the predicate permanently true, and re-fires
# every beat instead of every 30s. Cadence must come from the dispatch stamp,
# which advances whether or not the pass survives.
HB_FN=$(mo_func src/backend/main.mo "system func heartbeat(")
[ -n "$HB_FN" ] || _fail "could not extract heartbeat()"
src_lacks "heartbeat does not pace liquidations off the completion stamp" "$HB_FN" "now - _lastLiqNs"
src_has   "heartbeat paces liquidations off the dispatch stamp"           "$HB_FN" "armLiquidationDispatch"
ARM_FN=$(mo_func src/backend/main.mo "func armLiquidationDispatch(")
[ -n "$ARM_FN" ] || _fail "could not extract armLiquidationDispatch()"
src_has "dispatch arming advances the dispatch stamp"        "$ARM_FN" "_lastLiqDispatchNs := now"
src_has "an incomplete previous pass increments the streak"  "$ARM_FN" "_liqFailStreak += 1"
src_has "the streak is judged against the completion counter" "$ARM_FN" "_liqDispatches > _liqCompletions"
# Only a completed pass may clear the streak — clearing it on dispatch would
# make the backoff unreachable and restore the unthrottled retry.
TICK_FN=$(mo_func src/backend/main.mo "func tickLiquidations(")
[ -n "$TICK_FN" ] || _fail "could not extract tickLiquidations()"
src_has "a completed pass clears the failure streak" "$TICK_FN" "_liqFailStreak := 0"

# The market-maker freshness shield (OhShii #6.4). Stamps are written at
# PLACEMENT, so every path that cancels a staged intent before it lands must
# clear them, or staging-then-cancelling buys a free renewable shield. There are
# THREE near-identical staged-cancel blocks, and that is exactly how this went
# wrong the first time: the clear was added to cancelOwnSpotOrder alone while
# the endpoint users actually call kept its own copy. Assert on the shared
# helper, so a fourth copy of the block cannot quietly reintroduce it.
for fn in "func cancelOwnSpotOrder(" "func cancelMyOrder(" "func cancelAllUserOrders("; do
  BODY=$(mo_func src/backend/main.mo "$fn")
  [ -n "$BODY" ] || _fail "could not extract ${fn}"
  src_has "${fn%(*} clears the MM freshness shield" "$BODY" "clearMmShield"
done
# The deletes must live ONLY in the helper — an inlined copy is a path that can
# drift out of agreement again.
STAMP_DELETES=$(grep -c "Map.delete(mmQuoteStamp" src/backend/main.mo || true)
if [ "$STAMP_DELETES" -eq 1 ]; then _ok "mmQuoteStamp is cleared through one shared helper"
else _fail "mmQuoteStamp cleared in $STAMP_DELETES places — inline the calls through clearMmShield"; fi

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_deploy_hygiene\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_deploy_hygiene ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
