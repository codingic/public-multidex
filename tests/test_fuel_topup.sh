#!/bin/bash
# Treasury → cycles fuel loop (Stage 2) + archive fuel plumbing.
#
# Stage 2 burns treasury ledger-ICP for REAL cycles through the wired fuel
# route: icrc1_transfer to the CMC subaccount, notify_top_up, deposit. In dev
# the route is the fuel-mock (ledger + CMC in one canister) which actually
# deposit_cycles the DEX at 1 ICP → 1T, so this test asserts a genuine
# cycle-balance rise — the whole loop, no simulation gaps:
#   §1  route wired (cold_start) + treasury seeded
#   §2  burn 1.5 ICP → #ok ≈1.5T cycles; internal ICP debited exactly;
#       balance delta ≥ 1.4T; lifetime counters + FUEL event
#   §3  guards: zero amount / over-balance / unwired → clean errors, no debit
#   §4  archive fuel: adminFundArchive forwards cycles to the sidecar
# Does NOT resetExchange (touches only treasury ICP + cycle balances).
# Timers paused; sim killed (event-log grep needs a quiet log).

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
cycles() { adm getCanisterInfo '()' --query | tr -d '_' | grep -oE "cycles = [0-9]+" | head -1 | grep -oE "[0-9]+"; }

pkill -9 -f "simulate_trading.sh" 2>/dev/null || true
sleep 1
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true

echo "── §1 route wired + treasury seeded ──"
FUEL_MOCK_ID=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -z "$FUEL_MOCK_ID" ]; then
  nok "fuel-mock canister not deployed" "run icp deploy before this test"
  echo "RESULT: passed=$pass failed=$fail"; exit $fail
fi
adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" >/dev/null
# The mock forwards REAL cycles (1 ICP → 1T), so it needs a mintable balance —
# a fresh canister's default can't cover a 1.5T deposit. Local mint, free.
icp canister top-up --amount 20t fuel-mock >/dev/null 2>&1 || true
# Self-heal: a prior aborted run may have left a pending notify (stable).
adm adminRetryFuelNotify '(null)' >/dev/null 2>&1 || true
FS=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
if echo "$FS" | grep -q "$FUEL_MOCK_ID"; then ok "fuel route wired at the mock"; else nok "route not wired" "$FS"; fi
L0=$(echo "$FS" | tr -d '_' | grep -oE "lifetimeIcpE8s = [0-9]+" | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
# Field renders QUOTED ("principal" = "...") — the name collides with the
# candid keyword; the value is the second quoted token on the line.
TREAS=$(adm getTreasury '()' --query | tr -d '\n' | grep -oE '"principal" = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tail -1 | tr -d '"')
if [ -n "$TREAS" ]; then ok "treasury principal resolved ($TREAS)"; else nok "no treasury principal" "$(adm getTreasury '()' --query | head -c 120)"; fi
adm setTestBalance "(principal \"$TREAS\", \"ICP\", 200_000_000 : nat)" >/dev/null   # 2 ICP

echo "── §2 burn 1.5 ICP → real cycles ──"
C0=$(cycles)
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | tr -d '_' | grep -qE "ok = 1499[0-9]{9}"; then
  ok "burn returned ≈1.5T minted cycles"
else nok "burn result wrong" "$R"; fi
ICP_LEFT=$(adm getTestBalance "(principal \"$TREAS\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${ICP_LEFT:-x}" = "50000000" ]; then
  ok "internal ICP debited exactly (2 → 0.5 ICP)"
else nok "internal debit wrong" "left=$ICP_LEFT"; fi
C1=$(cycles)
DELTA=$(( ${C1:-0} - ${C0:-0} ))
if [ "$DELTA" -ge 1400000000000 ]; then
  ok "cycle balance rose by ≥1.4T (Δ=$DELTA) — deposit really landed"
else nok "no real cycle deposit" "Δ=$DELTA (before=$C0 after=$C1)"; fi
FS2=$(adm getFuelStatus '()' --query | tr -d '_\n' | tr -s ' ')
L1=$(echo "$FS2" | grep -oE "lifetimeIcpE8s = [0-9]+" | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [ "$(( ${L1:-0} - ${L0:-0} ))" = "150000000" ]; then
  ok "lifetime ICP-burned counter advanced by exactly 1.5 ICP"
else nok "lifetime counter wrong" "before=$L0 after=$L1"; fi
if echo "$FS2" | grep -q "pendingNotify = null"; then
  ok "no pending notify left behind"
else nok "pending notify stuck" "$(echo "$FS2" | head -c 200)"; fi
EV=$(adm getRecentEvents '(50 : nat)' --query 2>/dev/null | grep -c "FUEL: minted")
if [ "${EV:-0}" -ge 1 ]; then ok "mint is event-logged"; else nok "no FUEL event" "count=$EV"; fi

echo "── §3 guards ──"
R0=$(adm burnTreasuryIcpToCycles '(0 : nat)')
if echo "$R0" | grep -q "err"; then ok "zero amount refused"; else nok "zero accepted" "$R0"; fi
RB=$(adm burnTreasuryIcpToCycles '(999_999_999_999 : nat)')
if echo "$RB" | grep -q "err"; then ok "over-balance refused"; else nok "over-balance accepted" "$RB"; fi
adm setFuelRoute '(null, null)' >/dev/null
RU=$(adm burnTreasuryIcpToCycles '(50_000_000 : nat)')
if echo "$RU" | grep -q "not wired"; then ok "unwired route refused"; else nok "unwired accepted" "$RU"; fi
ICP_LEFT2=$(adm getTestBalance "(principal \"$TREAS\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${ICP_LEFT2:-x}" = "50000000" ]; then
  ok "failed attempts debited nothing"
else nok "guard leaked a debit" "left=$ICP_LEFT2"; fi
adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" >/dev/null   # restore

echo "── §4 archive fuel forwarding ──"
RA=$(adm adminFundArchive '(100_000_000_000 : nat)')
if echo "$RA" | tr -d '_' | grep -q "ok = 100000000000"; then
  ok "adminFundArchive forwarded 100B cycles to the sidecar"
elif echo "$RA" | grep -q "no archive sidecar"; then
  ok "no sidecar spawned on this deployment (fresh install) — guard answered cleanly"
else nok "archive funding failed" "$RA"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
