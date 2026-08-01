// MarginPools.mo — first-class margin pools & positions (PURE core), in integer
// base units (10^8 — see lib/Fixed.mo). `size` and PnL are SIGNED (Int);
// prices/values are Nat. The VWAP scale cancels (qty×price/qty = price); PnL =
// priceDiff × qty / SCALE with the sign applied separately.
//
// A margin pool is a user-owned sub-account principal. The existing
// principal-scoped engine (Accounts / BorrowEngine / MarginEngine / Liquidator)
// supplies a pool's collateral, debt, and health UNCHANGED — so this module
// holds no state and does no I/O. It owns the Pool / Position TYPES, the
// deterministic pool-principal derivation, the position accounting (`applyFill`)
// and the display math. See docs/margin-pools-design.md.

import Principal "mo:core/Principal";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Types "Types";
import Fixed "Fixed";

module {

  // Isolated => the engine refuses a second market in the pool (one position,
  // segregated risk). Cross => many positions share the pool's collateral.
  public type Mode = { #isolated; #cross };

  public type Pool = {
    id        : Nat;
    owner     : Principal;
    name      : Text;            // user-facing label ("BTC swing", "hedge")
    mode      : Mode;
    createdAt : Int;
  };

  // A first-class position inside a pool. `size` is reconciled to the pool's
  // real net exposure; `entryPrice` and `realizedPnl` are STORED truths
  // (not derivable from balances), updated by `applyFill` at settlement.
  public type Position = {
    poolId      : Nat;
    marketId    : Types.MarketId;
    baseToken   : Types.TokenId;
    size        : Int;          // signed base units: + long, − short
    entryPrice  : Nat;          // VWAP, in quote (ICPUSD)
    realizedPnl : Int;          // cumulative, in quote (signed)
    openedAt    : Int;
  };

  // ── Pool sub-account principal (deterministic, injective on poolId) ──
  // poolId comes from a GLOBAL counter, so it is globally unique; encode it
  // (tagged) into a 9-byte principal blob. Uniqueness by construction — no
  // hash required; the tag byte avoids colliding with II / AMM / insurance
  // principals. Authorization is by the registry (pools[poolId].owner).
  let POOL_TAG : Nat8 = 0x70; // 'p'

  public func poolPrincipal(poolId : Nat) : Principal {
    // byte 0 = tag, bytes 1..8 = poolId big-endian (supports 2^64 pools).
    let bytes = Array.tabulate<Nat8>(9, func(i : Nat) : Nat8 {
      if (i == 0) { POOL_TAG } else {
        let shift : Nat = (8 - i) * 8;      // i=1 → 56 … i=8 → 0
        Nat8.fromNat((poolId / (2 ** shift)) % 256)
      }
    });
    Principal.fromBlob(Blob.fromArray(bytes));
  };

  // ── Position accounting: apply a fill (PURE) ──────────────────────
  // `fillSize` is signed: +buy base, −sell base. Returns the new (size,
  // entryPrice) and the realized PnL this fill produced (in quote).
  // Standard perp accounting: VWAP on open/increase; realize on reduce/flip;
  // entry resets to fill price on a flip, to 0 when flat.
  public type FillResult = { size : Int; entryPrice : Nat; realizedDelta : Int };

  public func applyFill(size : Int, entry : Nat, fillSize : Int, fillPrice : Nat) : FillResult {
    if (fillSize == 0) { return { size; entryPrice = entry; realizedDelta = 0 } };
    let newSize = size + fillSize;
    let sameDir = size == 0 or ((size > 0) == (fillSize > 0));
    if (sameDir) {
      // Open or increase in the same direction → VWAP the entry.
      let absS = Int.abs(size);
      let absF = Int.abs(fillSize);
      // (|S|·entry + |F|·fill) / (|S|+|F|): the qty scale cancels → a price.
      let newEntry = if (absS + absF == 0) { fillPrice }
                     else { (absS * entry + absF * fillPrice) / (absS + absF) };
      { size = newSize; entryPrice = newEntry; realizedDelta = 0 }
    } else {
      // Reduce or flip → realize PnL on the closed quantity.
      let absS = Int.abs(size);
      let absF = Int.abs(fillSize);
      let reduceQty = Nat.min(absF, absS);
      // realized = (fill − entry) · reduceQty · dir, dir = sign(closed side).
      // Magnitude via mulDiv (round DOWN), then the sign applied.
      let mag = Fixed.mulDiv(Int.abs((fillPrice : Int) - (entry : Int)), reduceQty, Fixed.SCALE, false);
      let priceUp   = fillPrice >= entry;
      let longClose = size > 0;
      let realized : Int = if (priceUp == longClose) { mag } else { -mag };
      let newEntry =
        if (newSize == 0) { 0 }                  // flat
        else if (absF <= absS) { entry }         // pure reduce — entry unchanged
        else { fillPrice };                      // flip — remainder opens at fill
      { size = newSize; entryPrice = newEntry; realizedDelta = realized }
    }
  };

  // ── Display math (PURE) ───────────────────────────────────────────
  public func notional(size : Int, mark : Nat) : Nat { Fixed.mul(Int.abs(size), mark, false) };

  // Signed: a short (size < 0) profits when mark < entry.
  public func unrealizedPnl(size : Int, entry : Nat, mark : Nat) : Int {
    let mag = Fixed.mulDiv(Int.abs((mark : Int) - (entry : Int)), Int.abs(size), Fixed.SCALE, false);
    let markUp = mark >= entry;
    let isLong = size >= 0;
    if (markUp == isLong) { mag } else { -mag };
  };

  // Pool margin usage ∈ [0,1] (at 10^8); 1.0 = at the liquidation line.
  // The UX "% to liquidation" is 1 − usage.
  public func marginUsage(collateralUsd : Nat, debtUsd : Nat, maintenance : Nat) : Nat {
    if (debtUsd == 0) { return 0 };
    if (collateralUsd == 0) { return Fixed.SCALE };
    Nat.min(Fixed.SCALE, Fixed.mulDiv(maintenance, debtUsd, collateralUsd, true))
  };

  // Liquidation price for a LONG: P = (maint·debt − otherColl) / (size·ltv).
  // Returns null when cash margin alone already covers the debt.
  public func liqPriceLong(otherCollUsd : Nat, debtUsd : Nat, size : Int, ltv : Nat, maintenance : Nat) : ?Nat {
    if (size <= 0 or ltv == 0) { return null };
    let maintDebt = Fixed.mul(maintenance, debtUsd, true);
    if (maintDebt <= otherCollUsd) { return null };
    let num : Nat = maintDebt - otherCollUsd;
    let sizeLtv = Fixed.mul(Int.abs(size), ltv, false);
    if (sizeLtv == 0) { return null };
    ?Fixed.div(num, sizeLtv, false)
  };

  // Liquidation price for a SHORT: P = otherColl / (maint·|size|).
  public func liqPriceShort(otherCollUsd : Nat, sizeAbs : Nat, maintenance : Nat) : ?Nat {
    if (sizeAbs == 0 or maintenance == 0) { return null };
    ?Fixed.div(otherCollUsd, Fixed.mul(sizeAbs, maintenance, false), false)
  };

  // Distance from `mark` to a liquidation price, as a positive fraction (10^8).
  public func pctToLiq(mark : Nat, liq : ?Nat) : ?Nat {
    switch (liq) {
      case null { null };
      case (?p) { if (mark == 0) { null } else { ?Fixed.div(Int.abs((mark : Int) - (p : Int)), mark, false) } };
    }
  };
}
