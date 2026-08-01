# Limit-order position entry

*2026-06-11. Implemented. Lets a user open (and close) a margin position with a limit order — exact price, no slippage — instead of a market order.*

## Why it's small

The sealed model is already a deferred-order system: `parkDeferred(marketId, baseToken, owner, side, kind, price, qty, …)` takes a `kind` of `#market` or `#limit`, and `releaseDeferred` already *rests* a `#limit` leftover on the book. `openPosition` previously hardcoded `#market` with a slippage-cap price; limit entry is "thread a price through."

- **Market**: ceiling = slippage cap; releases and fills on the next GEPTOR (~1–2 s).
- **Limit**: ceiling = the user's price (no slippage); the leftover RESTS on the book owned by the pool principal and fills when the market reaches it. The Phase-3 settlement hook books each fill at the exact fill price — so the entry is exact.

## The one real decision: borrow timing (pre-borrow + disclosed carry)

`openPosition` borrows the leveraged shortfall **upfront**, sized at the price ceiling (`sizeBase × limitPrice` for a long). A resting leveraged limit must be fully funded to fill (the CLOB checks the maker's balance synchronously), so the borrow has to be present while resting. This is **safe**: `parkDeferred` soft-locks the order's funds, `getAvailable` excludes them, and `deleveragePool` only runs on a *fill* — so the borrow is never repaid out from under a resting order.

- Honest cost: a *leveraged* limit accrues borrow interest while it rests; a **1× limit borrows nothing** (zero carry — the clean common case).
- **Cancel repays it.** A resting limit-entry's cancel must release the reservation *and* `deleveragePool` (repay the now-idle borrow) — otherwise borrowed funds would sit idle. Verified end-to-end: open leveraged limit → debt = borrow; cancel → debt ≈ 0, margin returned.
- Rejected alternative — *borrow-at-fill* (no resting carry): would need the matching engine to call back into the borrow engine mid-fill. Deeper change for a small carry saving; revisit only if carry becomes a real concern.

## The correctness piece: settle fills everywhere

Because limit entries **rest**, the pool's order can be filled *outside* `releaseDeferred` — by the AMM sweep or the rebalancer. `releaseDeferred` already covers fills where any deferred release crosses a pool's resting limit (the fill is in that release's trades), so the only gaps are the two AMM-as-taker paths. `settlePoolFills` is now called at: `releaseDeferred` (existing), `ammSweepResting`, and `ammExecuteRebalance`. The paths are disjoint (each trade is produced in exactly one), so no double-booking.

## Surfacing + cancelling pool orders

Pool orders are owned by the *pool principal*, not the user, so they don't appear in `getMyOrders` and `cancelMyOrder` rejects them (owner ≠ caller). Two pool-scoped endpoints fill the gap:
- `getPoolOrders(poolId)` — the pool's open + staged orders (resting limit entries), owner-gated.
- `cancelPoolOrder(poolId, orderId)` — cancel a staged or resting pool order; refund the reservation and `deleveragePool` to repay the idle borrow.

The frontend shows the selected pool's resting orders under the open-position form with a Cancel button.

## What it unlocks for free

`closePosition` got the same optional `limitPrice` → **limit exits / take-profit**. Post-only/maker entry is the same `#limit` path. (Stop-loss is genuinely different — it needs a price-trigger watcher — and is out of scope.)

## API
- `openPosition(poolId, marketId, side, sizeBase, maxSlippage, limitPrice : ?Float)` — `null` = market (today's behavior); `?price` = limit.
- `closePosition(poolId, marketId, maxSlippage, limitPrice : ?Float)` — same.
- `getPoolOrders(poolId) : [Order]`, `cancelPoolOrder(poolId, orderId)`.
- Frontend: Market/Limit toggle + limit-price input on the open-position form; resting-orders list with cancel.
