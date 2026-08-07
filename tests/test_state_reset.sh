#!/bin/bash
# Verifies that resetExchange clears EVERY persistent collection.
# Catches the failure mode where someone adds a new top-level state
# field but forgets to add it to resetExchange — which leads to
# orphan data leaking between sessions and "test isolation" being
# silently broken.
#
# Strategy: seed `full` (which exercises every code path that writes
# state — orders, AMM pools, vault LP, oracle aggregates, vault P&L
# history, pending matches via the protection windows on AMM quotes,
# reservedBalances, etc.). Then call resetExchange. Then assert every
# observable is empty / zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_state_reset ──"
setup_mode full

# Sanity: full seed populated state. (If this assert fails the test
# is reading a broken seed, not exercising reset.)
PRE_VAULT=$(call getVaultValue '()')
PRE_LP=$(extract_float "lpSupply" "$PRE_VAULT")
assert_gt "seed populated vault" "${PRE_LP:-0}" "0"

# Snapshot some state writes that resetExchange has historically
# missed — these are the regressions we're locking against.
PRE_POOLS=$(call getAmmPools '()' | grep -c "marketId" || true)
PRE_AGG=$(call getLastAggregate '("BTC")' | grep -c "price = " || true)

# Margin-pool registry: create a pool pre-reset so we can assert the registry
# is wiped (2026-07-01 regression: pools survived resets as empty zombies and
# ids kept climbing across seed cycles).
call createMarginPool '("reset probe", false)' --identity alice > /dev/null

# Reset.
call resetExchange '()' --identity alice > /dev/null

# ── Every collection must read empty / zero ──────────────────────

# Pools
POOLS=$(call getAmmPools '()')
assert_contains "pools cleared" "$POOLS" "vec {}"

# Vault
VAULT=$(call getVaultValue '()')
LP=$(extract_float "lpSupply" "$VAULT")
TQV=$(extract_float "totalQuoteValue" "$VAULT")
assert_float_close "vaultLPSupply == 0" "0" "${LP:-0}" 0.0001
assert_float_close "totalQuoteValue == 0" "0" "${TQV:-0}" 0.0001

# Oracle aggregates
AGG=$(call getLastAggregate '("BTC")')
assert_contains "BTC aggregate cleared" "$AGG" "(null)"

# Pool value history (legacy ring buffer, vestigial but should clear).
HIST=$(call getPoolValueHistory '("BTC-ICPUSD")')
assert_contains "pool history cleared" "$HIST" "vec {}"

# Vault history: the AMM's 2s tick may have already inserted ONE
# fresh snapshot between resetExchange and our query. So we don't
# assert empty — instead we assert that any entries present reflect
# the post-reset world (lpSupply = 0). If the ring buffer were truly
# carrying pre-reset data, lpSupply on those entries would be non-
# zero from the prior session.
VHIST=$(call getVaultValueHistory '()')
NONZERO=$(echo "$VHIST" | grep -c "lpSupply = [^0]" || true)
assert_eq "no vault-history entries with non-zero lpSupply (i.e. no pre-reset leak)" "0" "$NONZERO"

# Per-user LP balances
ALICE_LP=$(call getMyVaultLp '()' --identity alice | grep -oE "[0-9.eE+-]+" | head -1)
assert_float_close "alice LP cleared" "0" "${ALICE_LP:-0}" 0.0001

# Reserved balances cleared (for the AMM principal — full mode would
# have created some via protected-quote pending matches).
AMM_PRI=$(call getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed 's/principal "//; s/"//')
# Use a registered identity to query — getMyReservedBalance is per-caller.
# Just check via the fact that no pending matches exist.
PEND=$(call getMyPendingMatches '()' --identity alice | grep -c "status =" || true)
assert_eq "no pending matches after reset" "0" "$PEND"

# Order book on every market is empty.
for m in BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD; do
  BOOK=$(call getOrderBook "(\"$m\")")
  ASKS=$(echo "$BOOK" | awk '/asks = vec {/,/}/' | grep -c "price =" || true)
  BIDS=$(echo "$BOOK" | awk '/bids = vec {/,/}/' | grep -c "price =" || true)
  assert_eq "$m asks cleared" "0" "$ASKS"
  assert_eq "$m bids cleared" "0" "$BIDS"
done

# AMM principal balances zeroed (the recently-added behavior).
# getTestBalance is scoped to self-or-controller — read as anonymous (the
# local controller) or a leaked balance would still read 0 and pass vacuously.
for t in BTC ETH SOL ICP ICPUSD; do
  BAL=$(call getTestBalance "(principal \"$AMM_PRI\", \"$t\")" --identity anonymous \
        | tr -d '_' | grep -oE "[0-9.eE+-]+" | head -1)
  assert_float_close "AMM principal $t balance zeroed" "0" "${BAL:-0}" 0.0001
done

# Treasury zeroed: resetExchange must clear BOTH the treasury balance and the
# lifetimeTreasuryFees counter (added with the maker/taker fee scheme — exactly
# the "new state field, stale reset" regression this test exists to catch).
TRE=$(call getTreasury '()')
assert_eq "treasury balance zeroed by reset"        "0" "$(extract_nat balanceUsd "$TRE")"
assert_eq "treasury lifetime fees zeroed by reset"  "0" "$(extract_nat lifetimeFeesUsd "$TRE")"

# Margin-pool registry wiped: the pre-reset probe pool must be gone AND ids
# must restart at 1 (a fresh pool after reset gets id 1, not a continuation).
MP=$(call getMyMarginPools '()' --identity alice)
assert_contains "margin pools cleared by reset" "$MP" "vec {}"
NEWPOOL=$(call createMarginPool '("post-reset probe", false)' --identity alice | tr -d '_')
assert_contains "pool ids restart at 1 after reset" "$NEWPOOL" "ok = 1"

finish_test "test_state_reset"
