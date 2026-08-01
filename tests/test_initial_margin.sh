#!/bin/bash
# Initial-margin gate — pool era. Risk-INCREASING actions must clear
# INITIAL_HEALTH_RATIO (1.25), not just maintenance (1.15), so a position can't
# be opened straight into near-liquidation territory.
#
# (Rewritten 2026-07: the original drove the removed whole-wallet margin API —
# openMarginAccount/borrowAsset — and its borrow-then-convert hole. Margin is
# pool-based now; openPosition IS the borrow+convert in one step, gated to
# INITIAL at stage time and re-clamped at release. The withdraw-side gate lives
# in test_margin_pools.sh §8.)
#
# ⚠️  Calls resetExchange — do not run against the live sim.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=img; icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 50000.0) : nat)"    >/dev/null

echo "── setup: pool funded with \$10k ──"
R=$(usr createMarginPool '("img pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 10000.0) : nat)" >/dev/null
C=$(fld collateralUsd "$(usr getMyMarginPools '()')")
if [ "${C:-0}" = "$(e8 10000)" ]; then ok "pool funded (\$10k collateral)"; else nok "setup" "coll=$C"; fi

echo "── A. Over-leveraged open (≈6×) REJECTED at the initial gate ──"
# 1.2 BTC ≈ $60k notional on $10k margin: borrow ~$50k, projected health far
# below INITIAL (1.25) → must be rejected outright at stage time.
A=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.2) : nat, $(e8 0.05) : nat, null)")
if echo "$A" | grep -qiE "initial|margin|health"; then ok "6× open rejected (initial-margin gate)"; else nok "over-leveraged open should be rejected" "$A"; fi
POS0=$(usr getMyPositions "()")
if ! echo "$POS0" | grep -q "BTC-ICPUSD"; then ok "no position created by the rejected open"; else nok "rejected open left a position" "$POS0"; fi

echo "── B. Modest open (≈1.5×) ACCEPTED and fills ──"
B=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.3) : nat, $(e8 0.05) : nat, null)")
if echo "$B" | grep -q "ok"; then ok "1.5× open accepted"; else nok "modest open should pass the gate" "$B"; fi
release
SZ=$(fld size "$(usr getMyPositions '()')")
if [ -n "${SZ:-}" ] && awk -v s="$SZ" 'BEGIN{exit (s>=25000000 && s<=31000000 ? 0 : 1)}'; then
  ok "position opened (size $(from_e8 "${SZ:-0}") BTC)"
else nok "position after release" "size=$SZ"; fi

echo "── C. Risk-increasing SECOND open that would breach → rejected; pool still healthy ──"
C2=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)")
if echo "$C2" | grep -qiE "initial|margin|health"; then ok "risk-increasing add-on rejected"; else nok "add-on breaching initial should be rejected" "$C2"; fi
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = false"; then ok "pool remains healthy"; else nok "pool health" "$HP"; fi

echo "── D. Risk-REDUCING close is always allowed, even with debt open ──"
D=$(usr closePosition "($PID, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if echo "$D" | grep -q "ok"; then ok "close (risk-reducing) accepted"; else nok "close should always be allowed" "$D"; fi
release
POS2=$(usr getMyPositions "()")
if ! echo "$POS2" | grep -q "BTC-ICPUSD"; then ok "position flattened"; else nok "close did not flatten" "$POS2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
