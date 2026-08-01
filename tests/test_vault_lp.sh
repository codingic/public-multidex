#!/bin/bash
# Unified vault LP accounting — anchor, cost-basis P&L, proportional withdraw.
#
# Under the fees-only model the FIRST deposit anchors valuePerLP at 1.0 (no
# genesis bonus) and seeds the cost basis. The vault reports gain/loss vs the
# total VALUE deposited (costBasis), not vs a fixed 1.0 anchor. A withdrawal
# pays the pro-rata basket NET of the 40bp exit fee (drain fix 5a: makes the
# deposit→withdraw round trip strictly dearer than trading the spread); the
# withheld slice stays in the vault, so an exit is a small GAIN for those who
# remain, never a loss. The first deposit into an empty vault must clear the
# $1000 floor (anti-inflation); alice (a canister controller) seeds it.

set -u
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.01}" 'BEGIN{d=(a-b); d=(d<0?-d:0-(-d)); exit ((d<0?-d:d) <= t*(b<0?-b:b)+t ? 0 : 1)}'; }

# Integer-money: methods take/return Nat BASE UNITS (10^8). e8 converts
# human → base for call args; from_e8 base → human so the assertions stay in
# human scale (valuePerLP ≈ 1.0, costBasis ≈ 150000, …). gainLossPct is a
# SIGNED Int at 10^8, so extraction keeps the sign.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

A=$(icp identity principal --identity alice 2>/dev/null | tail -1)   # alice = controller
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
asA()  { icp canister call --identity alice backend "$@" 2>&1; }
vv()   { yes | adm getVaultValue "()" 2>&1; }
# base-unit field extractor: strip Candid underscores FIRST, keep any sign.
field(){ tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+" | tail -1; }
# same, converted to human units for the human-scale assertions.
fieldh(){ local n; n=$(field "$1"); [ -z "$n" ] && n=0; from_e8 "$n"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
# Fund alice with 1 BTC + 100k cash for the genesis deposit.
for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$A\", \"$t\", 0 : nat)" >/dev/null; done
adm setTestBalance "(principal \"$A\", \"BTC\",    $(e8 1.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null

echo "── 1. Genesis deposit (controller) anchors valuePerLP=1.0 + cost basis ──"
# 1 BTC ($50k) + $100k cash = $150k value into an empty vault → mint == value.
MINT=$(asA depositLp "(\"BTC-ICPUSD\", $(e8 1.0) : nat, $(e8 100000.0) : nat)" | field ok)
MINT_H=$(from_e8 "${MINT:-0}")
echo "   minted: $MINT_H LP for \$150k deposited"
if near "$MINT_H" 150000 0.001; then ok "first deposit minted == value (150000, no bonus)"; else nok "genesis mint" "$MINT_H"; fi
V=$(vv)
if near "$(echo "$V" | fieldh valuePerLP)" 1.0 0.001; then ok "valuePerLP anchored at 1.0"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi
if near "$(echo "$V" | fieldh costBasis)" 150000 0.001; then ok "costBasis == deposited (150000)"; else nok "costBasis" "$(echo "$V" | fieldh costBasis)"; fi
if near "$(echo "$V" | fieldh gainLossPct)" 0.0 0.0001; then ok "gainLoss 0% at genesis"; else nok "gainLoss" "$(echo "$V" | fieldh gainLossPct)"; fi

echo ""
echo "── 2. Vault value rises 10% → reported gain tracks cost basis ──"
# BTC appreciates 50k→65k: vault 165k vs 150k basis → +10%.
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 65000.0) : nat)" >/dev/null
V=$(vv)
echo "   value=$(echo "$V" | fieldh totalQuoteValue) basis=$(echo "$V" | fieldh costBasis) gainLoss=$(echo "$V" | fieldh gainLossPct)"
if near "$(echo "$V" | fieldh gainLossPct)" 0.10 0.005; then ok "gainLoss reports +10% vs deposited cost basis"; else nok "gainLoss not +10%" "$(echo "$V" | fieldh gainLossPct)"; fi
if near "$(echo "$V" | fieldh valuePerLP)" 1.10 0.005; then ok "valuePerLP rose to 1.10"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi

echo ""
echo "── 3. Withdraw half → pro-rata basket NET of 40bp exit fee; basis scales ──"
SUPPLY=$(echo "$V" | field lpSupply)   # base-unit Nat; halve as an integer
HALF=$(awk -v s="$SUPPLY" 'BEGIN{printf "%.0f", s/2}')
WD=$(asA withdrawLp "(${HALF} : nat)")
WD_BTC=$(echo "$WD" | fieldh btc)
WD_USD=$(echo "$WD" | fieldh icpusd)
echo "   withdrew $(from_e8 "$HALF") LP → btc=$WD_BTC icpusd=$WD_USD"
# Gross half-share = 0.5 BTC + 50,000 ICPUSD; net of the 40bp exit fee =
# 0.498 / 49,800. A payout at the old gross values means the fee regressed
# (and the free at-mid basket swap is back).
if near "$WD_BTC" 0.498 0.002; then ok "withdrew 0.498 BTC (half share − 40bp exit fee)"; else nok "withdraw BTC not net-of-fee" "$WD_BTC"; fi
if near "$WD_USD" 49800 0.002; then ok "withdrew 49,800 ICPUSD (net of exit fee)"; else nok "withdraw USD not net-of-fee" "$WD_USD"; fi
V=$(vv)
if near "$(echo "$V" | fieldh costBasis)" 75000 0.01; then ok "costBasis scaled to 75000 (half)"; else nok "costBasis after withdraw" "$(echo "$V" | fieldh costBasis)"; fi
# The withheld fee slice stays in the vault: remaining LPs' gain RISES from
# +10.0% to ≈ +10.44% (82,830 value on a 75,000 basis). An exit must never
# cost those who remain.
if near "$(echo "$V" | fieldh gainLossPct)" 0.1044 0.003; then ok "gainLoss rose to ≈+10.44% (exit fee accrues to remaining LPs)"; else nok "gainLoss after exit" "$(echo "$V" | fieldh gainLossPct)"; fi

echo ""
echo "── 4. Withdraw the rest → supply zero; fee residue stays in the vault ──"
REM=$(asA getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1)
asA withdrawLp "(${REM} : nat)" >/dev/null
V=$(vv); LPLEFT=$(asA getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if near "$(echo "$V" | fieldh lpSupply)" 0.0 0.01 && near "$(from_e8 "${LPLEFT:-0}")" 0.0 0.01; then ok "vault + user LP both zero after full withdraw"; else nok "not zeroed" "supply=$(echo "$V" | fieldh lpSupply) user=${LPLEFT:-0}"; fi
if near "$(echo "$V" | fieldh costBasis)" 0.0 0.01; then ok "costBasis returns to zero"; else nok "costBasis not zero" "$(echo "$V" | fieldh costBasis)"; fi
# The final exit's 40bp slice (≈ $331 of the ~$82.8k remaining) stays behind
# with zero supply outstanding; the next genesis deposit absorbs it. Assert
# it's present — a zero here means the last withdrawer took gross.
TQV=$(echo "$V" | fieldh totalQuoteValue)
if near "$TQV" 331 0.15; then ok "exit-fee residue retained (~\$331)"; else nok "fee residue missing" "$TQV"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
