#!/bin/bash
# Regression: inventory-skew geometry must be ONE-SIDED and never cross ref.
#
# The defense rule (drain fix): inventory pressure may only WIDEN the ladder
# away from the reference price, never pull a side across it.
#   LONG base  → bids back away (down); asks HOLD at ref + half-spread (the
#                most competitive sell allowed — shedding happens at fair+).
#   SHORT base → asks carry a scarcity premium (up); bids HOLD at ref − half
#                (the most competitive refill allowed — buying below fair).
#
# History: v1 of the skew had its sign inverted (reinforcing drift); v2 fixed
# the sign but applied the lean to BOTH mids, so once |lean| exceeded the
# half-spread the ladder crossed ref — when short it BID ABOVE FAIR to refill
# inventory it had just sold at fair+half, a standing buy-high/sell-low round
# trip that adversarial flow cycled at scale (the play-net drain). Lock in the
# one-sided geometry AND the never-cross invariant.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_skew_direction ──"
setup_mode amm

AMM_PRI=$(call getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed 's/principal "//; s/"//')

# Seed mode `amm` set inventoryTargetBase = 2.0 BTC and refPrice = 75000.
# Crank intensity so the effect is large enough to grep for: 200bps at the
# ±1.0 deviation clamp. No-skew anchors: ask = 75150 (+20bp), bid = 74850.
call setAmmSkewConfig "(\"BTC-ICPUSD\", $(e8 2.0) : nat, 200 : nat)" --identity alice > /dev/null

top_of_book() {
  BOOK=$(call getOrderBook '("BTC-ICPUSD")')
  TOP_ASK_E8=$(echo "$BOOK" | awk '/asks = vec {/,/]/' | tr -d '_' \
    | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  TOP_BID_E8=$(echo "$BOOK" | awk '/bids = vec {/,/]/' | tr -d '_' \
    | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  TOP_ASK=$(from_e8 "${TOP_ASK_E8:-0}")
  TOP_BID=$([ -n "$TOP_BID_E8" ] && from_e8 "$TOP_BID_E8" || echo 0)
}

# ── Phase 1: heavily LONG (3.0 BTC = 50% over target → lean −100bp) ──
call setTestBalance "(principal \"$AMM_PRI\", \"BTC\", $(e8 3.0))" --identity alice > /dev/null
call requoteAmm '("BTC-ICPUSD")' --identity alice > /dev/null
top_of_book

assert_gt "got a numeric top ask" "${TOP_ASK:-0}" "0"
# Asks HOLD at the ref+half anchor — they must NOT chase the surplus down
# through ref (old v2 put this ask at ~74400, below fair: a guaranteed-loss
# sale of inventory bought at/above fair).
assert_gt "long-base ask holds at ref+half (never crosses ref)" "$TOP_ASK" "75000"
assert_lt "long-base ask stays anchored (no upward drift)"      "$TOP_ASK" "75300"
# Bids back away: < no-skew anchor 74850.
assert_lt "long-base shifts bid DOWN (less aggressive buying)" "${TOP_BID:-99999}" "74850"

# ── Phase 2: heavily SHORT (1.0 BTC = 50% under target → lean +100bp) ──
call setTestBalance "(principal \"$AMM_PRI\", \"BTC\", $(e8 1.0))" --identity alice > /dev/null
call requoteAmm '("BTC-ICPUSD")' --identity alice > /dev/null
top_of_book

# Asks carry the scarcity premium: > no-skew anchor 75150 (deficit 50% →
# +100bp lean ⇒ ask ≈ 75900; leave headroom for the floor barrier's extra).
assert_gt "short-base asks carry a premium (drain gets expensive)" "$TOP_ASK" "75200"
# Bids HOLD at ref−half — the CRITICAL never-cross assertion. Old v2 bid
# ~75600 here (above fair): the money pump this package removes.
assert_gt "short-base bid present" "${TOP_BID:-0}" "0"
assert_lt "short-base bid NEVER crosses ref (buys below fair only)" "$TOP_BID" "75000"
assert_gt "short-base bid stays at the competitive anchor" "$TOP_BID" "74500"

finish_test "test_skew_direction"
