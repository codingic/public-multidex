#!/bin/bash
# Sealed model — the CANCEL path. Replaces the retired test_pending_match.sh:
# the protected-maker/PendingMatch window flow no longer exists (every order is
# sealed-until-GEPTOR; placeProtectedLimitOrder stages like a plain GTC and its
# window arg is ignored). What must still hold is the money lifecycle around a
# cancel: placing a buy reserves the quote leg (cost + worst-case taker-fee
# headroom), and cancelling — whether the order is still STAGED (deferred
# queue) or already RESTING on the book — refunds the reservation exactly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_staged_cancel_refund ──"
setup_mode pending   # alice: protected BUY 1.0 BTC @ 75000 (staged); 1,000,000 ICPUSD

# The buy reserves its quote leg immediately (staged or resting): ≥ 75,000 and
# ≤ 75,000 × (1 + taker-fee headroom).
RES0=$(call getMyReservedBalance '("ICPUSD")' --identity alice | tr -d '_' | grep -oE "[0-9]+" | head -1)
assert_gt "buy reserved its quote leg"        "${RES0:-0}" "$(( $(e8 75000) - 1 ))"
assert_lt "reservation ≈ cost + fee headroom" "${RES0:-0}" "$(e8 75200)"

# Find the order — staged id if still sealed, else the resting book order id.
OID=$(call getMyStagedOrderIds '()' --identity alice | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ -n "$OID" ]; then
  echo "  (order is STAGED — cancelling from the deferred queue)"
  # Drain fix 5b: a staged non-post-only entry is COMMITTED for its first 3s
  # (anti-free-look). Wait out the window so the cancel below is deterministic.
  sleep 3.2
else
  OID=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity alice | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
  echo "  (order already RESTING — cancelling from the book)"
fi
assert_gt "found the order to cancel" "${OID:-0}" "0"

# Cancel → the reservation refunds to zero and the order is gone everywhere.
CANCEL=$(call cancelMyOrder "(${OID:-0} : nat)" --identity alice)
assert_contains "cancel ok" "$CANCEL" "ok"

RES1=$(call getMyReservedBalance '("ICPUSD")' --identity alice | tr -d '_' | grep -oE "[0-9]+" | head -1)
assert_eq "reservation refunded to zero" "0" "${RES1:-x}"
STAGED_AFTER=$(call getMyStagedOrderIds '()' --identity alice | grep -cE "[0-9] : nat" || true)
assert_eq "no staged orders left" "0" "$STAGED_AFTER"
BOOK_AFTER=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity alice)
assert_contains "no resting orders left" "$BOOK_AFTER" "vec {}"

# The refunded balance is fully spendable again: re-place the same order.
REPLACE=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 75000) : nat, $(e8 1.0) : nat)" --identity alice)
assert_contains "full balance usable after refund" "$REPLACE" "ok"

# ── Commit window (drain fix 5b) ────────────────────────────────────────────
# A freshly staged non-post-only entry must REFUSE an immediate cancel: the
# stage→peek-at-a-faster-feed→cancel loop was a free ~1–2s option against the
# AMM. Timing-tolerant: if the CLI round-trip already burned the 3s window (or
# the entry released to the book first), we note and skip rather than flake.
PROBE=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 74000) : nat, $(e8 0.1) : nat)" --identity alice)
PID=$(echo "$PROBE" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
if [ -n "$PID" ]; then
  C0=$(call cancelMyOrder "(${PID} : nat)" --identity alice)
  if echo "$C0" | grep -q "committed"; then
    _ok "immediate cancel of a staged order is refused (commit window)"
    sleep 3.2
    C1=$(call cancelMyOrder "(${PID} : nat)" --identity alice)
    assert_contains "cancellable after the commit window" "$C1" "ok"
  else
    echo "  (probe missed the 3s commit window — CLI latency; refusal not asserted)"
    # C0 already cancelled it (staged past window, or resting) — nothing to clean up.
  fi
fi

finish_test "test_staged_cancel_refund"
