// Unit tests for src/backend/lib/Fixed.mo — the fixed-point money primitive the
// whole ledger will route through. Pins the rounding direction (the solvency
// rule), and proves the no-overflow property that justifies arbitrary-precision
// Nat over Nat64.

import Fixed "../src/backend/lib/Fixed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Float "mo:core/Float";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── Fixed.test ──");

// ── mulDiv rounding ──
eqN("mulDiv exact", Fixed.mulDiv(3, 100, 10, false), 30);
eqN("mulDiv round down (7/2)", Fixed.mulDiv(7, 1, 2, false), 3);
eqN("mulDiv round up (7/2)",   Fixed.mulDiv(7, 1, 2, true), 4);
eqN("mulDiv round down (10/3)", Fixed.mulDiv(10, 1, 3, false), 3);
eqN("mulDiv round up (10/3)",   Fixed.mulDiv(10, 1, 3, true), 4);
eqN("mulDiv exact never over-rounds", Fixed.mulDiv(9, 1, 3, true), 3);

// solvency invariant: roundUp − roundDown ∈ {0,1}, and roundUp ≥ roundDown
let d = Fixed.mulDiv(100, 7, 13, false);
let u = Fixed.mulDiv(100, 7, 13, true);
truth("round up ≥ round down", u >= d);
truth("round up/down differ by ≤ 1", u - d <= 1);

// ── mul / div at the 10^8 scale ──
eqN("mul: 1.5 × 2.0 = 3.0", Fixed.mul(150_000_000, 200_000_000, false), 300_000_000);
eqN("div: 3.0 / 2.0 = 1.5", Fixed.div(300_000_000, 200_000_000, false), 150_000_000);

// ── no overflow: N×N/N = N for N > 2^64 (a Nat64 product would wrap/trap) ──
let big : Nat = 10_000_000_000_000_000_000; // 10^19, > 2^63
eqN("no overflow: big×big/big = big", Fixed.mulDiv(big, big, big, false), big);

// ── the ROUND-UP arithmetic (p + denom − 1) at scale — the solvency-critical path
//    (every "amount a user pays/owes" uses roundUp=true), never exercised big before ──
eqN("no overflow, round UP exact: big×big/big = big (no over-round)", Fixed.mulDiv(big, big, big, true), big);
// big×big = (big+1−1)^2 ≡ 1 (mod big+1): exact quotient big−1, remainder 1 → up = big.
eqN("big inexact round DOWN = big−1", Fixed.mulDiv(big, big, big + 1, false), big - 1 : Nat);
eqN("big inexact round UP   = big   (p+denom−1 carries, no overflow)", Fixed.mulDiv(big, big, big + 1, true), big);

// ── denom = 1: identity in both directions (round-up degenerate) ──
eqN("denom=1 round down = a×b", Fixed.mulDiv(7, 11, 1, false), 77);
eqN("denom=1 round up   = a×b", Fixed.mulDiv(7, 11, 1, true), 77);

// ── the "a user owes at least 1 base unit" rule: tiny non-zero owed amount never rounds to 0 ──
eqN("owe 1/3 base unit rounds DOWN to 0 (receive)", Fixed.mulDiv(1, 1, 3, false), 0);
eqN("owe 1/3 base unit rounds UP to 1 (pay/owe)",   Fixed.mulDiv(1, 1, 3, true), 1);
eqN("owe exactly 0 stays 0 even rounding up",        Fixed.mulDiv(0, 5, 3, true), 0);

// ── boundary conversions ──
eqN("fromFloat 1.5 → base units", Fixed.fromFloat(1.5), 150_000_000);
eqN("fromFloat 0 → 0", Fixed.fromFloat(0.0), 0);
eqN("fromFloat negative → 0", Fixed.fromFloat(-5.0), 0);
truth("toFloat 2.5 round-trip", Float.abs(Fixed.toFloat(250_000_000) - 2.5) < 0.0000001);

Debug.print("── Fixed.test PASSED ──");
