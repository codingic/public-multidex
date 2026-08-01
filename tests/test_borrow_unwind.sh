#!/bin/bash
# openPosition borrow UNWIND (review L1, fixed in 3de29fe).
#
# openPosition borrows the leverage shortfall BEFORE staging the entry. If
# parkDeferred then refuses, the pool used to be left holding the borrowed
# funds + accruing interest with NO order to deploy them — a latent leak the
# user could only clean up manually via repayAsset. The fix repays the exact
# just-borrowed amount on the failure path.
#
# Deterministic trigger: the per-owner staged-queue cap (32). Fill the pool's
# 32 staged slots with tiny entries that need NO borrow (pool equity covers
# them), then attempt a 33rd big enough to force a borrow:
#   borrow succeeds (small vs the health cap) → parkDeferred returns null at
#   the cap (checked before funding) → the unwind path must repay.
# Same-timestamp borrow+repay accrues zero interest, so the pool's debt must
# come back to EXACTLY 0 — before the fix it stayed at ≈ the borrowed amount.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
ID=bunwind; icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --identity $ID backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

# The sim must be DEAD: its trading fires GEPTORs that would RELEASE the
# staged entries below (they'd rest on the book), deflating the staged count
# this test builds up to the cap. cold_start relaunches it later.
pkill -9 -f "simulate_trading.sh" 2>/dev/null || true
sleep 1

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null   # vault = lender
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 50000.0) : nat)" >/dev/null

echo "── setup: cross pool funded \$10k ──"
R=$(usr createMarginPool '("unwind", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 10000.0) : nat)" >/dev/null
[ -n "${PID:-}" ] && ok "pool created + funded (id=$PID)" || nok "pool setup" "$R"

echo "── fill all 32 staged slots with tiny NO-borrow entries ──"
OKS=0
for i in $(seq 1 32); do
  O=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.0003) : nat, $(e8 0.05) : nat, opt ($(e8 50000.0) : nat))")
  echo "$O" | grep -q '#ok\|= ok\|ok' && OKS=$((OKS+1))
done
if [ "$OKS" -eq 32 ]; then ok "32 tiny limit entries staged (pool equity covered them — no borrow)"; else nok "expected 32 staged entries" "got $OKS"; fi

D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ "${D0:-x}" = "0" ]; then ok "pool debt is 0 before the capped attempt (control)"; else nok "pre-attempt debt should be 0" "debt=$D0"; fi

# Non-vacuity guard: the 33rd entry needs $10,500 of quote; prove the pool's
# free quote is LESS, so openPosition provably had to borrow before parking.
F0=$(fld freeQuote "$(usr getMyMarginPools '()')")
if [ -n "${F0:-}" ] && awk -v f="$F0" -v need="$(e8 10500.0)" 'BEGIN{exit (f < need ? 0 : 1)}'; then
  ok "free quote \$$(awk -v f="$F0" 'BEGIN{printf "%.0f", f/100000000}') < \$10,500 needed — the borrow branch WILL fire"
else nok "precondition broken: pool could cover the 33rd entry without borrowing (test would be vacuous)" "freeQuote=$F0"; fi

echo "── 33rd entry: forces a borrow, then hits the staged cap at parkDeferred ──"
# 0.25 BTC @ 42,000 limit = \$10,500 quote needed; available ≈ \$9,519 after the
# 32 locks → borrows ≈ \$981 (well under the health cap) → park refuses (cap).
O33=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.25) : nat, $(e8 0.05) : nat, opt ($(e8 42000.0) : nat))")
if echo "$O33" | grep -q "Could not stage"; then
  ok "33rd open refused at the staged cap (borrow had already happened)"
else nok "expected 'Could not stage' from the cap" "$O33"; fi

D1=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ "${D1:-x}" = "0" ]; then
  ok "borrow UNWOUND: pool debt is exactly 0 after the failed staging"
else nok "borrow leaked — pool left holding debt with no order" "debtUsd=$D1 (≈ the un-repaid borrow)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
