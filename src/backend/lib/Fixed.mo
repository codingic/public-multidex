// Fixed.mo — fixed-point money arithmetic.
//
// Every balance, amount, and price in the exchange is an integer in a uniform
// 10^8 base-unit scale (e8s / the ICRC ledger standard): 1.0 whole token =
// SCALE base units. `Nat` for non-negative amounts, `Int` for signed values
// (PnL, long/short position size, debt deltas). These are arbitrary-precision
// bignums, so an intermediate product (price × quantity) can NEVER overflow —
// which is the whole reason to use them over Nat64.
//
// THE CARDINAL RULE: every inexact division rounds AGAINST the user / toward
// protocol solvency — round DOWN what a user receives, round UP what they pay or
// owe. Dust accrues to the protocol; value is never created from rounding, so
// "Σ balances = Σ deposits" holds exactly and every old Float ε-tolerance goes
// away. `mulDiv` is the ONLY multiply-divide primitive; pass roundUp = (this
// amount is something the user pays or owes).

import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";

module {
  // 8 decimals. 1.0 whole token = SCALE base units.
  public let DECIMALS : Nat = 8;
  public let SCALE : Nat = 100_000_000;

  // (a × b) / denom with explicit rounding. Arbitrary-precision: the a×b product
  // cannot overflow. roundUp=true rounds the quotient UP (for amounts a user
  // PAYS / OWES); roundUp=false truncates DOWN (for amounts a user RECEIVES).
  // Precondition: denom > 0 (a caller bug otherwise — traps, no state change).
  public func mulDiv(a : Nat, b : Nat, denom : Nat, roundUp : Bool) : Nat {
    let p = a * b;
    if (roundUp) { (p + denom - 1) / denom } else { p / denom };
  };

  // Multiply two SCALE-fixed values → a SCALE-fixed value: (a × b) / SCALE.
  public func mul(a : Nat, b : Nat, roundUp : Bool) : Nat { mulDiv(a, b, SCALE, roundUp) };

  // Divide two SCALE-fixed values → a SCALE-fixed ratio: (a × SCALE) / b.
  public func div(a : Nat, b : Nat, roundUp : Bool) : Nat { mulDiv(a, SCALE, b, roundUp) };

  // External whole-token Float (an oracle price, a UI amount) → base units.
  // Quantises Float input onto the integer grid AT INGEST so nothing Float ever
  // reaches a settlement. Truncates toward zero; a caller needing a specific
  // direction should round explicitly afterwards.
  public func fromFloat(x : Float) : Nat {
    if (x <= 0.0) { 0 } else { Int.abs(Float.toInt(x * Float.fromInt(SCALE))) };
  };

  // Base units → whole-token Float, for DISPLAY / logging only (never feeds a
  // settlement).
  public func toFloat(u : Nat) : Float { Float.fromInt(u) / Float.fromInt(SCALE) };
};
