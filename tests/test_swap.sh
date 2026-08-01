#!/bin/bash
# Verifies the swap endpoint's three routing modes:
#   1. quote → base       (ICPUSD → BTC, executes a market BUY)
#   2. base → quote       (BTC → ICPUSD, executes a market SELL)
#   3. base → base via quote (BTC → ETH, staged cross-swap, both legs atomic)
#
# Sealed-until-GEPTOR model: every market-order swap STAGES (the call returns
# fromAmount=0 / fullyFilled=false / swapOrderId=opt N) and only settles on the
# next GEPTOR after a FRESH oracle fetch + requote (anti-snipe). Each route
# stages, forces a release, then polls for the settled balance.
#
# Uses `full` mode so all three markets have ≥1 layer of book depth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_swap ──"
# `full` seed WITHOUT the 14d CoinGecko history backfill: the swap routes only
# need markets + funded AMM pools + book depth, and the multi-thousand-call
# history injection reliably kills the local pocket-ic mid-test.
bash "$SCRIPT_DIR/scripts/seed.sh" full --history-days 0 > /tmp/uplands-test-seed.log 2>&1 \
  || { echo "seed.sh full failed — see /tmp/uplands-test-seed.log" >&2; exit 1; }

# Set up a fresh swapper so the named seed traders' books stay
# untouched.
icp identity new swapper --storage plaintext 2>/dev/null || true
SW=$(principal_of swapper)

# Fund swapper with both legs so all three swap routes are testable.
# (Integer-money migration: setTestBalance takes Nat BASE UNITS at 10^8.)
call setTestBalance "(principal \"$SW\", \"ICPUSD\", $(e8 100000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$SW\", \"BTC\",    $(e8 1)      : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$SW\", \"ETH\",    $(e8 20)     : nat)" --identity alice > /dev/null

# Swapper's balance in BASE UNITS (getBalance returns a Nat now; Candid may
# print it with underscores — extract_first_nat strips them first).
swapper_bal() { local n; n=$(extract_first_nat "$(call getBalance "(\"$1\")" --identity swapper)"); echo "${n:-0}"; }

# Force a sealed-model release on one market: re-stamp the pool's CURRENT
# refPrice (counts as a fresh fetch without moving the market), then requote —
# the GEPTOR that follows settles staged swaps/orders on that market.
release_market() {
  local m="$1" px
  px=$(call getAmmPool "(\"$m\")" | tr -d '_' | grep -oE "refPrice = [0-9]+" | grep -oE "[0-9]+" | head -1)
  [ -n "$px" ] || { echo "release_market: no refPrice for $m" >&2; return 1; }
  call setAmmRefPrice "(\"$m\", $px : nat)" --identity alice > /dev/null
  call requoteAmm "(\"$m\")" --identity alice > /dev/null
}

# ── Route 1: ICPUSD → BTC ────────────────────────────────────────
# Spend $5,000 on BTC at market with 5% slippage. Amount + maxSlippage are
# e8 Nats now (maxSlippage is an e8 FRACTION of 1).
SW1=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"BTC\";
  amount    = $(e8 5000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.05) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_contains "ICPUSD→BTC swap accepted" "$SW1" "ok"
assert_contains "ICPUSD→BTC staged (sealed model, swapOrderId returned)" "$SW1" "swapOrderId = opt"

release_market "BTC-ICPUSD"
wait_for "[ \"\$(swapper_bal BTC)\" -gt $(e8 1) ]" 20 1
BTC_BAL=$(from_e8 "$(swapper_bal BTC)")
assert_gt "swapper BTC balance grew" "$BTC_BAL" "1.0"

# ── Route 2: BTC → ICPUSD ────────────────────────────────────────
USD_BEFORE2=$(swapper_bal ICPUSD)
SW2=$(call swap "(record {
  fromToken = \"BTC\";
  toToken   = \"ICPUSD\";
  amount    = $(e8 0.05) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.05) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_contains "BTC→ICPUSD swap accepted" "$SW2" "ok"

release_market "BTC-ICPUSD"
wait_for "[ \"\$(swapper_bal ICPUSD)\" -gt $USD_BEFORE2 ]" 20 1
ICPUSD_BAL=$(from_e8 "$(swapper_bal ICPUSD)")
assert_gt "BTC→ICPUSD proceeds landed" "$ICPUSD_BAL" "$(from_e8 "$USD_BEFORE2")"
# Started with 100k, spent 5k on BTC (≈$5k out), got back the proceeds of
# selling 0.05 BTC. Final >$90k easily covers any slippage + fees.
assert_gt "swapper ICPUSD balance" "$ICPUSD_BAL" "90000"

# ── Route 3: BTC → ETH (cross-market) ───────────────────────────
ETH_BEFORE3=$(swapper_bal ETH)
SW3=$(call swap "(record {
  fromToken = \"BTC\";
  toToken   = \"ETH\";
  amount    = $(e8 0.05) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.10) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_contains "BTC→ETH cross-swap accepted" "$SW3" "ok"
assert_contains "BTC→ETH staged (deferred until BOTH legs fresh)" "$SW3" "swapOrderId = opt"

# A cross-swap releases only once BOTH legs' markets are fresh; the deferred
# processor is normally timer-driven — force it for determinism.
release_market "BTC-ICPUSD"
release_market "ETH-ICPUSD"
call adminRunDeferredSwaps '()' --identity alice > /dev/null
wait_for "[ \"\$(swapper_bal ETH)\" -gt $ETH_BEFORE3 ]" 20 1

# ETH balance should have grown (started at 20, gained some).
ETH_BAL=$(from_e8 "$(swapper_bal ETH)")
assert_gt "swapper ETH balance grew" "$ETH_BAL" "20.0"

finish_test "test_swap"
