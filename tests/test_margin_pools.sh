#!/bin/bash
# Margin pools — first-class, segregated margin sub-accounts.
#
# ⚠️  DO NOT RUN AGAINST THE LIVE SIM: this calls resetExchange and wipes the
#     seeded sim state. Run it in a clean replica, or after stopping the sim.
#
# Verifies: a pool is a user-owned sub-account; margin is funded INTO it (the
# segregation boundary); openPosition borrows the shortfall + stages the trade
# AS THE POOL; the staged trade releases on a requote; getMyPositions reports the
# derived long with a liquidation price; closePosition flattens it (close
# proceeds auto-repay the debt); withdraw is health-gated; and another user
# cannot touch the pool.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money: methods take/return Nat base units (10^8).
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=mpool;  icp identity new $ID  --storage plaintext 2>/dev/null || true
ID2=mpool2; icp identity new $ID2 --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID  2>/dev/null | tail -1)

adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
usr()  { icp canister call --identity $ID  backend "$@" 2>&1; }
usr2() { icp canister call --identity $ID2 backend "$@" 2>&1; }
# release a market's staged (sealed) orders: advance the ref price then requote.
release() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
# extract the first integer of a named base-unit field (underscore-stripped)
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null  # vault: lender + book cash
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null  # vault: BTC inventory to sell
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 100000.0) : nat)"   >/dev/null  # user free wallet

echo "── 1. Create a (cross) pool ──"
R=$(usr createMarginPool '("BTC swing", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$PID" ]; then ok "pool created (id=$PID)"; else nok "createMarginPool" "$R"; fi

echo "── 2. Free wallet is NOT collateral until funded ──"
H0=$(usr getMyMarginPools "()")
C0=$(fld collateralUsd "$H0")
if [ "${C0:-x}" = "0" ]; then ok "new pool collateral = 0"; else nok "expected empty pool" "$H0"; fi

echo "── 3. Fund the pool with \$30k (segregation boundary) ──"
F=$(usr fundMarginPool "($PID, $(e8 30000.0) : nat)")
if echo "$F" | grep -q "ok"; then ok "funded \$30k into pool"; else nok "fundMarginPool" "$F"; fi
C1=$(fld collateralUsd "$(usr getMyMarginPools '()')")
if [ "${C1:-0}" = "$(e8 30000)" ]; then ok "pool collateral = 30k"; else nok "pool collateral after fund" "got $C1"; fi

echo "── 4. Another user cannot fund/open my pool ──"
X=$(usr2 fundMarginPool "($PID, $(e8 1.0) : nat)")
if echo "$X" | grep -qi "not your pool"; then ok "foreign fund rejected"; else nok "auth" "$X"; fi

echo "── 5. Open a 1 BTC long (≈\$50k notional on \$30k margin ⇒ ~1.7×) ──"
O=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)")
if echo "$O" | grep -q "ok"; then ok "openPosition staged (borrowed the shortfall, gated to INITIAL)"; else nok "openPosition" "$O"; fi
release "BTC-ICPUSD" 50000.0   # postdate + requote → releases the staged buy

echo "── 6. Position is a first-class long: exact entry booked at fill ──"
POS=$(usr getMyPositions "()")
SZ=$(fld size "$POS")
if [ -n "${SZ:-}" ] && awk -v s="$SZ" 'BEGIN{exit (s>=90000000 && s<=105000000 ? 0 : 1)}'; then
  ok "long size ≈ 1 BTC ($(from_e8 "${SZ:-0}"))"
else nok "position size" "size=$SZ"; fi
EP=$(fld entryPrice "$POS")
if [ -n "${EP:-}" ] && awk -v p="$EP" 'BEGIN{exit (p>=4500000000000 && p<=5300000000000 ? 0 : 1)}'; then
  ok "entry ≈ fill price ($(from_e8 "${EP:-0}")), not provisional"
else nok "entryPrice" "entry=$EP"; fi
if echo "$POS" | grep -q "liqPrice = opt"; then ok "liquidation price reported"; else nok "liqPrice" "$POS"; fi
# Auto-deleverage repaid the UNUSED borrow on open, so debt ≈ the leveraged part
# (~$20k = $50k notional − $30k collateral, ± fills/fees).
D1=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ -n "${D1:-}" ] && awk -v d="$D1" 'BEGIN{exit (d>=1000000000000 && d<=2600000000000 ? 0 : 1)}'; then
  ok "debt ≈ leveraged portion ($(from_e8 "${D1:-0}")) — unused borrow repaid"
else nok "debt after open" "debt=$D1"; fi

echo "── 7. Pool health reflects the leveraged long (debt > 0, healthy) ──"
HP=$(usr getMyMarginPools "()")
D2=$(fld debtUsd "$HP")
if [ -n "${D2:-}" ] && [ "$D2" != "0" ] && echo "$HP" | grep -q "isLiquidatable = false"; then
  ok "pool carries debt and is healthy"
else nok "pool health" "$HP"; fi

echo "── 8. Withdraw blocked while the position is open ──"
# The property: collateral cannot be pulled out from under an open leveraged
# position. Depending on composition the rejection is either the free-cash
# guard (the pool's cash became the BTC position) or the initial-margin health
# gate — both prove the money can't escape. The contrast is step 9's
# "withdrawable after close".
W=$(usr withdrawMarginPool "($PID, $(e8 29000.0) : nat)")
if echo "$W" | grep -qiE "initial.margin|health|Insufficient free"; then ok "over-withdraw blocked while levered ($(echo "$W" | grep -oE '"[^"]*"' | head -1))"; else nok "withdraw gate" "$W"; fi

echo "── 9. Close the position (stage offsetting sell + release) ──"
C=$(usr closePosition "($PID, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if echo "$C" | grep -q "ok"; then ok "closePosition staged"; else nok "closePosition" "$C"; fi
release "BTC-ICPUSD" 50000.0
POS2=$(usr getMyPositions "()")
if echo "$POS2" | grep -qE "vec \{\}|record \{\}" || ! echo "$POS2" | grep -q "BTC-ICPUSD"; then ok "position flattened"; else nok "still open after close" "$POS2"; fi
# Closing proceeds auto-repaid the loan → pool debt ≈ 0. Integer-money rounds
# AGAINST the user (toward solvency), so a dust residue (< $0.01) is correct,
# not unpaid debt.
D3=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ -n "${D3:-}" ] && awk -v d="$D3" 'BEGIN{exit (d < 1000000 ? 0 : 1)}'; then
  ok "loan repaid from close proceeds (residual dust: $D3 base units)"
else nok "debt after close" "debt=$D3"; fi
W2=$(usr withdrawMarginPool "($PID, $(e8 1000.0) : nat)")
if echo "$W2" | grep -q "ok"; then ok "equity withdrawable after close"; else nok "withdraw after close" "$W2"; fi

echo "── 10. Isolated pool: PENDING entries occupy it too (guard bypass fix) ──"
# The isolated guard used to key only on FILLED size (poolNetSize ≠ 0), so an
# UNFILLED staged/resting entry on market A (derived size still 0) let a second
# open on market B through — once both filled, the "isolated" pool held two
# markets. The guard now also refuses while live orders exist on another market,
# and self-clears when they cancel/fill.
adm createAmmPool '("SOL-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 150.0) : nat)" >/dev/null
adm enableAmm '("SOL-ICPUSD", true)' >/dev/null 2>&1 || true   # openPosition needs an ENABLED pool's price
R2=$(usr createMarginPool '("iso", true)')
PID2=$(echo "$R2" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID2, $(e8 5000.0) : nat)" >/dev/null
# LIMIT entry on BTC far below market → stages now, rests (no fill) on release.
O1=$(usr openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.02) : nat, $(e8 0.05) : nat, opt ($(e8 40000.0) : nat))")
if echo "$O1" | grep -q "ok"; then ok "isolated pool: pending BTC limit entry staged"; else nok "iso BTC entry" "$O1"; fi
O2=$(usr openPosition "($PID2, \"SOL-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, null)")
if echo "$O2" | grep -q "pending order on another market"; then
  ok "STAGED entry on BTC blocks a SOL open (was the bypass)"
else nok "isolated guard should refuse while a pending entry exists" "$O2"; fi
release "BTC-ICPUSD" 50000.0   # limit@40k doesn't cross — now RESTS on the book
O3=$(usr openPosition "($PID2, \"SOL-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, null)")
if echo "$O3" | grep -q "pending order on another market"; then
  ok "RESTING entry on BTC still blocks a SOL open"
else nok "isolated guard should refuse while a resting entry exists" "$O3"; fi
# Cancel the resting BTC entry → the guard self-clears; SOL open now succeeds.
OID2=$(usr getPoolOrders "($PID2)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
CX=$(usr cancelPoolOrder "($PID2, ${OID2:-0} : nat)")
if echo "$CX" | grep -q "ok"; then ok "pending BTC entry cancelled"; else nok "cancelPoolOrder" "$CX"; fi
O4=$(usr openPosition "($PID2, \"SOL-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, null)")
if echo "$O4" | grep -q "ok"; then ok "guard self-cleared after cancel — SOL open accepted"; else nok "guard failed to clear" "$O4"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
