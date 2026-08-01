// Unit tests for src/backend/lib/SafeMath.mo — the saturating subtraction that
// guards ~6 real settlement sites (MatchingEngine availability, Liquidator
// refunds, LiquidityManager shrink, OrderBook candle pagination). Nat `-` TRAPS
// on underflow, so subOrZero is the "clamp to zero" idiom named once. These pin
// the three cases (a>b, a==b, a<b→0), the no-overflow property (values > 2^64),
// and the identities that must hold vs. a raw subtraction.

import SafeMath "../src/backend/lib/SafeMath";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── SafeMath.test ──");

// ── the three cases ──
eqN("a > b → a - b",        SafeMath.subOrZero(10, 3), 7);
eqN("a == b → 0",           SafeMath.subOrZero(5, 5), 0);
eqN("a < b → 0 (clamp, no trap)", SafeMath.subOrZero(3, 10), 0);

// ── zero edges ──
eqN("b == 0 → a",           SafeMath.subOrZero(42, 0), 42);
eqN("a == 0, b > 0 → 0",    SafeMath.subOrZero(0, 42), 0);
eqN("0 - 0 → 0",            SafeMath.subOrZero(0, 0), 0);

// ── off-by-one around the clamp boundary ──
eqN("a = b+1 → 1",          SafeMath.subOrZero(101, 100), 1);
eqN("a = b-1 → 0",          SafeMath.subOrZero(99, 100), 0);

// ── no overflow: operands far beyond 2^64 (a Nat64 subtraction would wrap) ──
let big : Nat  = 100_000_000_000_000_000_000; // 10^20, > 2^64
let big2 : Nat = 100_000_000_000_000_000_001;
eqN("big - (big-1) → 1",    SafeMath.subOrZero(big2, big), 1);
eqN("big - big → 0",        SafeMath.subOrZero(big, big), 0);
eqN("(big-1) - big → 0",    SafeMath.subOrZero(big, big2), 0);
eqN("big - 0 → big",        SafeMath.subOrZero(big, 0), big);

// ── invariant: agrees with raw subtraction whenever a >= b, else 0 ──
// (spot-check a spread of pairs, including equal and inverted)
for ((a, b) in [(0, 0), (1, 0), (0, 1), (7, 4), (4, 7), (1_000_000, 999_999), (999_999, 1_000_000)].vals()) {
  let got = SafeMath.subOrZero(a, b);
  let want = if (a >= b) { a - b : Nat } else { 0 };
  truth("subOrZero(" # debug_show a # "," # debug_show b # ") == max(0,a-b)", got == want);
};

// ── result is never negative and never exceeds a (saturating downward only) ──
truth("result <= a always", SafeMath.subOrZero(50, 20) <= 50 and SafeMath.subOrZero(20, 50) <= 20);

Debug.print("── SafeMath.test PASSED ──");
