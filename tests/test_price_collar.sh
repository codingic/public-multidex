#!/bin/bash
# Price collar: tight on MARKETABLE orders, loose on RESTING ones.
#
# The 100x band (PRICE_BAND_FACTOR) is a fat-finger guard — its own error text
# says "likely an input error" — and it permits a print anywhere from mark/100
# to mark*100. Two colluding accounts could therefore move value at will: one
# rests far off the mark, the other takes it, and thousands of dollars cross on
# a trade that is not a trade. The board ranks on profit, so a bought print is
# a bought rank. Self-trade prevention does not see this: the two sides are
# genuinely different beneficiaries.
#
# The collar binds only orders that would EXECUTE NOW, and stays wide for
# orders that merely rest. The asymmetry is the point:
#
#   * A RESTING order priced absurdly is an OFFER to the whole venue, not a
#     transfer. Anyone can take it — including the protocol arbitrageur, which
#     exists to take exactly this — so the attacker cannot choose who fills it.
#     Far-from-market resting orders are also a legitimate strategy (a bid far
#     below, waiting for a crash), so banning them would cost real function to
#     prevent nothing.
#   * A MARKETABLE order names the price AND the counterparty, because it
#     executes against a specific resting order in the same instant. That is
#     where the transfer actually happens, so that is what the collar binds.
#
# What this pins:
#   §1 a marketable buy far ABOVE the mark is REFUSED (the wash take)
#   §2 a marketable sell far BELOW the mark is REFUSED (the other direction)
#   §3 a RESTING sell far above the mark is ALLOWED (waiting for a rally)
#   §4 a RESTING buy far below the mark is ALLOWED (waiting for a crash)
#   §5 ordinary trading at the mark is untouched
#   §6 the loose fat-finger band still catches genuinely absurd input
#
# NOTE on direction, which is easy to get backwards: a SELL far BELOW the mark
# is marketable (it crosses the bid and executes at once), and a SELL far ABOVE
# it rests. Buys are the mirror. "Far from the mark" alone does not say which.
#
# ⚠️ Places real orders on the configured venue; cancels what it places.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_price_collar ──"

PICK=$(icp canister call backend getAmmPools '()' --query --identity anonymous 2>&1 \
  | tr '}' '\n' | grep -oE 'marketId = "[^"]*"' | head -1 | grep -oE '"[^"]*"' | tr -d '"')
MKT="${PICK:-BTC-ICPUSD}"
BASE="${MKT%%-*}"

newid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
U="collar_u"; newid "$U"
UPRIN=$(icp identity principal --identity "$U" 2>/dev/null | tail -1)

MARK=$(call getAmmPool "(\"$MKT\")" --query --identity anonymous | grep -oE 'refPrice = [0-9_]+' | head -1 | grep -oE '[0-9_]+' | tr -d '_')
if [ -z "${MARK:-}" ] || [ "$MARK" = "0" ]; then
  echo "  SKIP: $MKT has no reference price on this venue"; exit 0
fi
QTY=$(python3 -c "print(max(1, (20000000000 * 100000000) // $MARK))")
HIGH=$(python3 -c "print($MARK * 50)")      # 50x — inside the 100x band, far outside 5%
LOW=$(python3 -c "print($MARK // 50)")
ABSURD=$(python3 -c "print($MARK * 500)")   # outside the 100x fat-finger band too
echo "  market=$MKT mark=$MARK qty=$QTY"

# Fund generously: a resting bid 50x above the mark reserves 50x the notional,
# and these assertions must fail on the COLLAR, never on the balance.
call setTestBalance "(principal \"$UPRIN\", \"ICPUSD\", 900000000000000 : nat)" --identity anonymous >/dev/null
call setTestBalance "(principal \"$UPRIN\", \"$BASE\", 5000000000 : nat)" --identity anonymous >/dev/null

place()   { call placeLimitOrder   "(\"$MKT\", variant { $1 }, $2 : nat, ${3:-$QTY} : nat)" --identity "$U"; }
placePO() { call placeLimitOrderPO "(\"$MKT\", variant { $1 }, $2 : nat, ${3:-$QTY} : nat, null)" --identity "$U"; }
# A far-BELOW price makes the notional tiny (price x qty), so a fixed quantity
# falls under the venue's minimum order value and is refused for THAT reason —
# nothing to do with the collar. Scale the quantity to keep the notional
# constant wherever the price is.
QTY_LOW=$(python3 -c "print($QTY * 60)")
COLLAR="must be within"
FATFINGER="likely an input error"

# ── §1/§2 marketable, far from the mark → refused ──
assert_contains "§1 marketable buy 50x ABOVE the mark is refused" "$(place buy "$HIGH")" "$COLLAR"
assert_contains "§2 marketable sell 50x BELOW the mark is refused" "$(place sell "$LOW" "$QTY_LOW")" "$COLLAR"

# ── §3/§4 resting, far from the mark → allowed ──
# Post-only guarantees these REST (maker-or-kill), so reaching an id proves the
# collar let them through rather than the book happening to be empty.
R=$(placePO sell "$HIGH")
assert_not_contains "§3 resting sell far ABOVE the mark is not collared" "$R" "$COLLAR"
assert_contains     "§3 ...and actually rests" "$R" "id ="
R=$(placePO buy "$LOW" "$QTY_LOW")
assert_not_contains "§4 resting buy far BELOW the mark is not collared" "$R" "$COLLAR"
assert_contains     "§4 ...and actually rests" "$R" "id ="

# ── §5 ordinary trading is untouched ──
R=$(place buy "$MARK")
assert_not_contains "§5 a buy AT the mark is not collared" "$R" "$COLLAR"
R=$(place sell "$MARK")
assert_not_contains "§5 a sell AT the mark is not collared" "$R" "$COLLAR"
# Just inside the collar must pass; just outside must not.
IN=$(python3 -c "print(int($MARK * 1.04))")
OUT=$(python3 -c "print(int($MARK * 1.06))")
assert_not_contains "§5 marketable buy +4% (inside the collar) passes" "$(place buy "$IN")" "$COLLAR"
assert_contains     "§5 marketable buy +6% (outside) is refused"       "$(place buy "$OUT")" "$COLLAR"

# ── §6 the loose fat-finger band still applies to everything ──
# 500x is outside the 100x band, so even a RESTING order is refused — and by
# the fat-finger rule, not the collar.
assert_contains "§6 a resting sell 500x above the mark still hits the 100x band" \
  "$(placePO sell "$ABSURD")" "$FATFINGER"

call cancelAllMyOrders '(null)' --identity "$U" >/dev/null 2>&1 || true
echo "y" | icp identity delete "$U" >/dev/null 2>&1 || true

finish_test "price_collar"
