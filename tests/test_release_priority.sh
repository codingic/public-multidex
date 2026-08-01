#!/bin/bash
# L2 effect ordering (docs/access-prioritization-design.md §6), on EARNED
# levels (docs/progressive-incentives-design.md — L4 via setTestScorecard).
#   A. Rank priority at the GEPTOR release: a level-4 quoter's staged order
#      takes effect BEFORE a level-0 user's staged EARLIER in the same batch
#      window — (rank DESC, ts ASC) beats FIFO across ranks.
#   B. Quote freshness shield on the users-only (oracle-stall) path: an L4
#      quoter with RECENT staged intent has their resting quotes taken OFF the
#      fallback's menu — the expiring taker fills the worse-priced plain-user
#      ask instead of picking off the L4's better one.
# Fixture: enabled AMM pool with numLevels=0 (GEPTOR runs, no AMM quotes) —
# the test_orderbook_priority pattern. Timers paused; releases driven manually.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
MKR=$(mkid rp_maker); DEP=$(mkid rp_dep); MM=$(mkid rp_mm); PLN=$(mkid rp_plain); WHL=$(mkid rp_whale)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
mkr() { icp canister call --identity rp_maker backend "$@" 2>&1; }
dep() { icp canister call --identity rp_dep   backend "$@" 2>&1; }
mm()  { icp canister call --identity rp_mm    backend "$@" 2>&1; }
pln() { icp canister call --identity rp_plain backend "$@" 2>&1; }
whl() { icp canister call --identity rp_whale backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
newest_trade() { adm getRecentTrades '("BTC-ICPUSD")' | tr -d '_' ; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, 0 : nat, 0:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
for P in "$MKR" "$DEP" "$MM" "$PLN" "$WHL"; do
  adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 1000000.0) : nat)" >/dev/null
  adm setTestBalance "(principal \"$P\", \"BTC\",    $(e8 10.0) : nat)"      >/dev/null
done
# Earn L4 (rank 2 + shield): W = 2×$50k ≥ the $100k bar (1% scale on the
# fresh exchange) + qualified uptime (25/30 ≥ 50% over ≥20 samples).
adm setTestScorecard "(principal \"$MM\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" >/dev/null

echo "── A. tier priority: MM staged LATER beats depositor staged EARLIER ──"
# One resting ask with room for exactly one of the two buyers.
mkr placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50000) : nat, $(e8 0.1) : nat)" >/dev/null
release   # maker's ask rests
dep placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 50000) : nat, $(e8 0.1) : nat)" >/dev/null
sleep 1   # ensure a strictly later ts for the MM (FIFO would favor the depositor)
mm  placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 50000) : nat, $(e8 0.1) : nat)" >/dev/null
release   # one pass releases both staged buys — MM must go first
T=$(newest_trade)
if echo "$T" | grep -q "buyer = principal \"$MM\""; then
  ok "the trade's buyer is the MM (tier priority beat FIFO)"
else nok "expected the MM to take the ask" "$(echo "$T" | grep -oE 'buyer = principal "[^"]+"' | head -1)"; fi
DEPO=$(dep getMyOrdersOnMarket '("BTC-ICPUSD")')
if echo "$DEPO" | tr -d '_' | grep -q "price = $(e8 50000)"; then
  ok "the depositor's buy rested unfilled (the ask was gone)"
else nok "depositor order should rest at 50000" "$DEPO"; fi

echo "── B. stale-path shield: recent MM intent takes their book off the fallback menu ──"
# MM's BETTER ask vs a plain user's WORSE ask; both rest.
mm  placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50080) : nat, $(e8 0.2) : nat)" >/dev/null
pln placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50120) : nat, $(e8 0.2) : nat)" >/dev/null
release
# Whale stages a market buy; MM stages fresh repricing intent (sets the shield).
whl placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 0.2) : nat, $(e8 0.05) : nat, false)" >/dev/null
mm  placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50085) : nat, $(e8 0.05) : nat)" >/dev/null
# Force the whale's order down the users-only EXPIRY path (no fresh price).
SID=$(whl getMyStagedOrderIds '()' | tr -d '_' | grep -oE "[0-9]+" | head -1)
adm setTestDeferredExpiry "(${SID:-0} : nat, 1 : int)" >/dev/null 2>&1
adm adminRunDeferredExpiry "()" >/dev/null 2>&1
T2=$(newest_trade)
if echo "$T2" | grep -q "seller = principal \"$PLN\""; then
  ok "fallback filled the PLAIN user's worse ask — the shielded MM ask was skipped"
else nok "expected the plain ask (50120) to fill, not the shielded MM ask (50080)" "$(echo "$T2" | grep -oE 'seller = principal "[^"]+"|price = [0-9]+' | head -2)"; fi
MMO=$(mm getMyOrdersOnMarket '("BTC-ICPUSD")' | tr -d '_')
if echo "$MMO" | grep -q "price = $(e8 50080)"; then
  ok "the MM's better ask survived the stall untouched"
else nok "MM ask should still be resting" "$MMO"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
