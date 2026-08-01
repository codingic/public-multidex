#!/bin/bash
# tests/test_treasury_fees.sh
#
# NON-DESTRUCTIVE guard on the protocol fee/treasury CONFIGURATION plus a treasury
# solvency invariant. The pieces of the fee story are covered across the suite:
#   • the fee ARITHMETIC (buyer pays C+takerFee, seller gets C−makerFee, treasury
#     gets both, Σ QUOTE conserved, exempt-counterparty leg) → MatchingEngine.test.mo
#   • fees actually accrue on live fills → demonstrated by the running simulator
#     (getTreasury.lifetimeFeesUsd climbs)
#   • resetExchange zeroes the treasury → test_state_reset.sh
# This file pins the published fee SCHEDULE and the balance-vs-lifetime invariant,
# so a constant/accounting regression is caught cheaply on every run without
# needing a deterministic fill (which the sealed-matching model makes finicky).
#
# Safe to run anytime: it only issues a query, never resets or trades.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_treasury_fees ──"

TRE=$(call getTreasury '()')

# Published fee schedule: maker 5 bps, taker 10 bps, taker strictly dearer.
MK=$(extract_nat makerFeeBps "$TRE")
TK=$(extract_nat takerFeeBps "$TRE")
assert_eq "maker fee = 5 bps"  "5"  "${MK:-x}"
assert_eq "taker fee = 10 bps" "10" "${TK:-x}"
assert_gt "taker fee > maker fee (DOS-defensive)" "${TK:-0}" "${MK:-0}"

# LP fee share (drain fix 4): half of every settled fee accrues to the vault,
# published so UIs/reconciliation never hardcode the split.
SHARE=$(extract_nat lpFeeShareBps "$TRE")
assert_eq "LP fee share = 5000 bps (50%)" "5000" "${SHARE:-x}"

# Solvency invariant: the spendable treasury balance can never exceed the lifetime
# fees ever accrued (balance = lifetimeFees − whatever was converted to fuel). A
# violation means fees are being double-counted or the balance minted from nowhere.
BAL=$(extract_nat balanceUsd "$TRE")
LIFE=$(extract_nat lifetimeFeesUsd "$TRE")
if python3 -c "import sys; sys.exit(0 if ${BAL:-0} <= ${LIFE:-0} else 1)"; then
  _ok "treasury balance ≤ lifetime fees accrued (${BAL:-0} ≤ ${LIFE:-0})"
else
  _fail "treasury balance ${BAL:-0} exceeds lifetime fees ${LIFE:-0}"
fi

# Split invariant: the vault share floors per fill (treasury keeps the dust),
# so the vault's lifetime take can never exceed the treasury's.
VLIFE=$(extract_nat lifetimeVaultFeesUsd "$TRE")
if python3 -c "import sys; sys.exit(0 if ${VLIFE:-0} <= ${LIFE:-0} else 1)"; then
  _ok "vault lifetime fee share ≤ treasury's (${VLIFE:-0} ≤ ${LIFE:-0})"
else
  _fail "vault fee share ${VLIFE:-0} exceeds treasury lifetime ${LIFE:-0}"
fi

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_treasury_fees\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_treasury_fees ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
