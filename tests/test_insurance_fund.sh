#!/bin/bash
# Insurance fund / bad-debt resolution — pool era.
# (Rewritten 2026-07: the original built an insolvent whole-wallet user via the
# removed borrowAsset API. Same promise, pool-shaped: a pool so far underwater
# that collateral can't cover debt must be CLOSED — the covered slice drawn
# from the insurance buffer, the excess tallied as uncovered bad debt — never
# left as a perpetually-liquidatable zombie.)
#
# Setup: seed a deliberately SMALL insurance buffer ($3k). A $30k pool longs
# 1 BTC (~$20k debt), then BTC crashes 50k → 12k: collateral value < debt →
# insolvent. The batch must: write the pool's debt off (not zombie it), drain
# the buffer toward 0, and tally uncoveredBadDebtUsd > 0 for the shortfall
# beyond the buffer. ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=insf; icp identity new $ID --storage plaintext 2>/dev/null || true
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
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 100000.0) : nat)"   >/dev/null

echo "── seed a small \$3k insurance buffer ──"
adm seedInsuranceFund "($(e8 3000.0) : nat)" >/dev/null
INS0=$(adm getInsuranceFund '()')
BUF0=$(fld bufferUsd "$INS0"); UBD0=$(fld uncoveredBadDebtUsd "$INS0")
if [ "${BUF0:-0}" = "$(e8 3000)" ]; then ok "buffer seeded (\$3k)"; else nok "seedInsuranceFund" "buf=$BUF0"; fi

echo "── setup: \$30k pool, 1 BTC long — then a catastrophic crash to 12k ──"
R=$(usr createMarginPool '("insf pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
[ -n "${D0:-}" ] && [ "$D0" != "0" ] && ok "long open, debt \$$(from_e8 "$D0")" || nok "setup" "debt=$D0"

adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 12000.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then ok "pool deeply underwater (insolvent territory)"; else nok "should be liquidatable at 12k" "$HP"; fi

echo "── batch: insolvent pool CLOSED — buffer drained, shortfall tallied ──"
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
INS1=$(adm getInsuranceFund '()')
BUF1=$(fld bufferUsd "$INS1"); UBD1=$(fld uncoveredBadDebtUsd "$INS1")
D1=$(fld debtUsd "$(usr getMyMarginPools '()')")

# The debt is written OFF (cleared to at most $1 of dust), not left as a zombie.
if [ -n "${D1:-}" ] && awk -v d="$D1" 'BEGIN{exit (d < 100000000 ? 0 : 1)}'; then
  ok "insolvent debt written off (\$$(from_e8 "$D0") → \$$(from_e8 "$D1"))"
else nok "insolvent pool should be closed, not a zombie" "debt after=$D1"; fi

# The buffer absorbed first…
if awk -v a="${BUF1:-0}" -v b="${BUF0:-0}" 'BEGIN{exit (a<b?0:1)}'; then
  ok "insurance buffer absorbed the covered slice (\$$(from_e8 "${BUF0:-0}") → \$$(from_e8 "${BUF1:-0}"))"
else nok "buffer should drain on insolvency" "before=$BUF0 after=$BUF1"; fi

# …and the excess became realised uncovered bad debt.
if awk -v a="${UBD1:-0}" -v b="${UBD0:-0}" 'BEGIN{exit (a>b?0:1)}'; then
  ok "uncovered bad debt tallied beyond the buffer (+\$$(from_e8 $(( ${UBD1:-0} - ${UBD0:-0} ))))"
else nok "shortfall beyond the buffer should be tallied" "before=$UBD0 after=$UBD1"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
