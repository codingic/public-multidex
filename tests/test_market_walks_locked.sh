#!/bin/bash
# Verifies a market order walks past AMM-protected makers as their slices
# get locked by pending matches, instead of stopping on the first level.
#
# Before this fix: market buy for 10 ETH would lock the best AMM ask (say
# 1.5 ETH) into one pending match, then the matcher would re-find the same
# maker, see availableForFill == 0, and break — returning ~1.5 ETH instead
# of 10. After: matcher marks the exhausted maker as visited, advances to
# the next-best AMM ask, repeats until either the request is satisfied or
# slippage / book runs out.

set -u
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1 — $2"; }

ID=walk_locked
icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)

# Plenty of ICPUSD so taker budget isn't the constraint.
icp canister call --identity anonymous backend setTestBalance \
  "(principal \"$P\", \"ICPUSD\", 10000000.0:float64)" >/dev/null

# Place a deep market buy on ETH-ICPUSD. 25% slippage so we walk the
# AMM ladder hard. 10 ETH × ~$2000 ≈ $20k well within budget.
RES=$(icp canister call --identity $ID backend placeMarketOrder \
  '("ETH-ICPUSD", variant { buy }, 10.0:float64, 0.25:float64, false)' 2>&1)

# Sum totalFilled (immediate fills) + Σ pendingMatches.quantity.
FILLED=$(echo "$RES" | grep -oE "totalFilled = [0-9_.]+" | head -1 | sed 's/totalFilled = //;s/_//g')
PENDING_SUM=$(echo "$RES" | awk '
  /pendingMatches = vec \{/ { inpm = 1; next }
  inpm && /quantity = [0-9_.]+/ { gsub(/[^0-9.]/, "", $0); print; }
' | awk '{s+=$1} END {print s}')
[ -z "$PENDING_SUM" ] && PENDING_SUM=0

echo "Response (head):"
echo "$RES" | head -c 600
echo ""
echo "--- summary ---"
echo "totalFilled (immediate): $FILLED"
echo "Σ pendingMatches.qty:    $PENDING_SUM"
TOTAL=$(awk -v a="$FILLED" -v b="$PENDING_SUM" 'BEGIN { print a + b }')
echo "Σ all settled+pending:   $TOTAL"

# Expect ≥ 9 ETH soaked up (allow a bit of slop for slippage cutoff).
OK=$(awk -v t="$TOTAL" 'BEGIN { print (t >= 9.0) ? 1 : 0 }')
if [ "$OK" = "1" ]; then
  pass "market buy soaked >= 9 ETH (across immediate + pending). Was: $TOTAL"
else
  fail "Engine stopped after only $TOTAL ETH — locked-maker walk-through broken" "$RES"
fi
