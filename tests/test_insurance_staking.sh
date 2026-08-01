#!/bin/bash
# Insurance-fund STAKING — the user-staked junior tranche, pool era.
# (Rewritten 2026-07: the liquidatees are margin POOLS now — the removed
# whole-wallet borrowAsset API built them directly before.)
#
# Stakers deposit ICPUSD for shares, EARN liquidation penalties (share value
# rises on a SOLVENT liquidation) and ABSORB insolvent bad debt before LPs
# (share value falls on an INSOLVENT one). Walkthrough:
#   stake $10k → solvent pool liquidation → staker value RISES (yield)
#   → insolvent pool liquidation → staker value FALLS (absorption)
#   → unstake all → pro-rata ICPUSD comes back, buffer empties.
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
S=$(mkid ins_staker)     # the insurance staker
U1=$(mkid ins_liq1)      # solvent liquidatee (generates yield)
U2=$(mkid ins_liq2)      # insolvent liquidatee (drains the pool)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
asS() { icp canister call --identity ins_staker backend "$@" 2>&1; }
as1() { icp canister call --identity ins_liq1 backend "$@" 2>&1; }
as2() { icp canister call --identity ins_liq2 backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
stakeval() { fld valueUsd "$(asS getMyInsuranceStake '()')"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$S\",  \"ICPUSD\", $(e8 50000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$U1\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$U2\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null

# helper: create+fund a pool and open a 1 BTC long for a given identity fn
open_pool() { # $1 = caller fn name
  local R PID
  R=$($1 createMarginPool '("stk pool", false)')
  PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
  $1 fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
  $1 openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
  release
}

echo "── 1. stake \$10k → shares at value 1.0 ──"
ST=$(asS stakeInsurance "($(e8 10000.0) : nat)")
if echo "$ST" | grep -q "ok"; then ok "staked \$10k"; else nok "stakeInsurance" "$ST"; fi
V0=$(stakeval)
if [ -n "${V0:-}" ] && awk -v v="$V0" 'BEGIN{exit (v>=999000000000 && v<=1000100000000 ? 0 : 1)}'; then
  ok "stake value ≈ \$10k ($(from_e8 "$V0"))"
else nok "initial stake value" "v=$V0"; fi

echo "── 2. SOLVENT liquidation → penalty accrues → stake value RISES ──"
open_pool as1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25000.0) : nat)" >/dev/null   # under maintenance (liq px ≈ 25.9k), still solvent
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
V1=$(stakeval)
if awk -v a="${V1:-0}" -v b="${V0:-0}" 'BEGIN{exit (a>b?0:1)}'; then
  ok "yield: stake value rose ($(from_e8 "$V0") → $(from_e8 "$V1"))"
else nok "solvent liquidation should lift stake value (penalty → stakers)" "before=$V0 after=$V1"; fi

echo "── 3. INSOLVENT liquidation → pool absorbs → stake value FALLS ──"
release   # restore 50k so the next pool can open
open_pool as2
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 12000.0) : nat)" >/dev/null   # collateral < debt → insolvent
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
V2=$(stakeval)
if awk -v a="${V2:-0}" -v b="${V1:-0}" 'BEGIN{exit (a<b?0:1)}'; then
  ok "absorption: stake value fell ($(from_e8 "$V1") → $(from_e8 "$V2"))"
else nok "insolvency should drain the junior tranche" "before=$V1 after=$V2"; fi

echo "── 4. unstake all → pro-rata remainder returns ──"
SH=$(fld shares "$(asS getMyInsuranceStake '()')")
BAL0=$(fld '' "$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")")")
BAL0=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
UN=$(asS unstakeInsurance "(${SH:-0} : nat)")
if echo "$UN" | grep -q "ok"; then ok "unstaked ${SH:-0} shares"; else nok "unstakeInsurance" "$UN"; fi
BAL1=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
GOT=$(( ${BAL1:-0} - ${BAL0:-0} ))
# The redemption ≈ the last observed stake value (± dust rounding toward the pool).
if awk -v g="$GOT" -v v="${V2:-0}" 'BEGIN{d=g-v; if(d<0)d=-d; exit (d <= 100000 ? 0 : 1)}'; then
  ok "pro-rata redemption ≈ stake value (\$$(from_e8 "$GOT"))"
else nok "redemption mismatch" "got=$GOT expected≈$V2"; fi
SH2=$(fld shares "$(asS getMyInsuranceStake '()')")
if [ "${SH2:-x}" = "0" ]; then ok "no shares left"; else nok "shares should be zero" "left=$SH2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
