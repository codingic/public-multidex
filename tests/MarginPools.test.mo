// Pure-function unit tests for src/backend/lib/MarginPools.mo in integer base
// units (10^8). Pins the position-accounting math (VWAP entry, realized PnL on
// reduce/flip), the display math, and — the strong check — the conservation
// invariant cashflow + size·mark == realized + uPnL, which holds EXACTLY in
// integers (no tolerance). Runs in moc's interpreter via `mops test`.

import MP "../src/backend/lib/MarginPools";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func eqI(name : Text, a : Int, b : Int) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func nearN(name : Text, a : Nat, b : Nat, tol : Nat) {
  let d = if (a > b) { a - b } else { b - a };
  if (d > tol) { Runtime.trap("FAIL: " # name # " — expected ~" # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── MarginPools.test ──");

// ── applyFill: open / increase (VWAP) / reduce (realize) / flip / close ──
// (prices ×10^8: $100 = 10_000_000_000; sizes ×10^8: 2 BTC = 200_000_000)

// open a long: 2 @ 100
let f1 = MP.applyFill(0, 0, 200_000_000, 10_000_000_000);
eqI("open long: size", f1.size, 200_000_000);
eqN("open long: entry = fill", f1.entryPrice, 10_000_000_000);
eqI("open long: no realized", f1.realizedDelta, 0);

// increase: +2 @ 120 → VWAP (2@100 + 2@120 = 4 @ 110)
let f2 = MP.applyFill(f1.size, f1.entryPrice, 200_000_000, 12_000_000_000);
eqI("increase: size", f2.size, 400_000_000);
eqN("increase: VWAP entry 110", f2.entryPrice, 11_000_000_000);
eqI("increase: no realized", f2.realizedDelta, 0);

// reduce by 1 @ 130 → realize (130-110)*1 = +20, entry unchanged
let f3 = MP.applyFill(f2.size, f2.entryPrice, -100_000_000, 13_000_000_000);
eqI("reduce: size", f3.size, 300_000_000);
eqN("reduce: entry unchanged", f3.entryPrice, 11_000_000_000);
eqI("reduce: realized +20", f3.realizedDelta, 2_000_000_000);

// flip: sell 4 @ 90 → reduceQty min(4,3)=3, realized (90-110)*3 = -60, remainder -1 @ 90
let f4 = MP.applyFill(f3.size, f3.entryPrice, -400_000_000, 9_000_000_000);
eqI("flip: size now short", f4.size, -100_000_000);
eqN("flip: entry = fill", f4.entryPrice, 9_000_000_000);
eqI("flip: realized -60", f4.realizedDelta, -6_000_000_000);

// fully close a short → entry resets to 0; (90-80)*1 short = +10
let c0 = MP.applyFill(-100_000_000, 9_000_000_000, 100_000_000, 8_000_000_000);
eqI("close short: flat size", c0.size, 0);
eqN("close short: entry reset", c0.entryPrice, 0);
eqI("close short: realized +10", c0.realizedDelta, 1_000_000_000);

// ── Conservation: cashflow + size·mark == realizedTotal + uPnL (EXACT) ──
let fills : [(Int, Nat)] = [
  (200_000_000, 10_000_000_000), (200_000_000, 12_000_000_000),
  (-100_000_000, 13_000_000_000), (-400_000_000, 9_000_000_000)
];
var size : Int = 0; var entry : Nat = 0; var realizedTotal : Int = 0; var cashflow : Int = 0;
for ((fs, fp) in fills.vals()) {
  let r = MP.applyFill(size, entry, fs, fp);
  size := r.size; entry := r.entryPrice; realizedTotal += r.realizedDelta;
  cashflow += -(fs * fp) / 100_000_000;       // quote out on buys, in on sells
};
let mark : Nat = 9_000_000_000;
let lhs : Int = cashflow + (size * mark) / 100_000_000;
let rhs : Int = realizedTotal + MP.unrealizedPnl(size, entry, mark);
eqI("conservation: cashflow PnL = -40", lhs, -4_000_000_000);
eqI("conservation: cashflow == position PnL", lhs, rhs);

// ── unrealizedPnl signs ──
eqI("long uPnL up", MP.unrealizedPnl(200_000_000, 10_000_000_000, 11_000_000_000), 2_000_000_000);
eqI("short uPnL on price fall", MP.unrealizedPnl(-200_000_000, 10_000_000_000, 9_000_000_000), 2_000_000_000);
eqI("short uPnL on price rise", MP.unrealizedPnl(-200_000_000, 10_000_000_000, 11_000_000_000), -2_000_000_000);

// ── notional & marginUsage (maint 1.15 = 115_000_000) ──
eqN("notional abs", MP.notional(-300_000_000, 5_000_000_000), 15_000_000_000);
eqN("usage: no debt = 0", MP.marginUsage(100_000_000_000, 0, 115_000_000), 0);
// coll 1150, debt 1000, maint 1.15 → usage = 1.0 (at the line)
eqN("usage at line", MP.marginUsage(115_000_000_000, 100_000_000_000, 115_000_000), 100_000_000);
// coll 2300, debt 1000 → usage = 0.5 → 50% to liq
eqN("usage half", MP.marginUsage(230_000_000_000, 100_000_000_000, 115_000_000), 50_000_000);

// ── liquidation price ──
// LONG: 2 BTC, ltv 0.85, debt $120k, no other coll, maint 1.15 →
// P = (1.15*120000)/(2*0.85) = 138000/1.7 = 81176.47
switch (MP.liqPriceLong(0, 12_000_000_000_000, 200_000_000, 85_000_000, 115_000_000)) {
  case (?p) { nearN("liqPriceLong 81176.47", p, 8_117_647_058_824, 4) };
  case null { Runtime.trap("FAIL: liqPriceLong returned null") };
};
// LONG already safe: cash margin $200k covers maint*debt → null
truth("liqPriceLong null when safe", MP.liqPriceLong(20_000_000_000_000, 12_000_000_000_000, 200_000_000, 85_000_000, 115_000_000) == null);
// SHORT: cash $100k, |size| 1 BTC, maint 1.15 → P = 100000/1.15 = 86956.52
switch (MP.liqPriceShort(10_000_000_000_000, 100_000_000, 115_000_000)) {
  case (?p) { nearN("liqPriceShort 86956.52", p, 8_695_652_173_913, 4) };
  case null { Runtime.trap("FAIL: liqPriceShort returned null") };
};

// pctToLiq: mark 100000, liq 80000 → 20%
switch (MP.pctToLiq(10_000_000_000_000, ?8_000_000_000_000)) {
  case (?d) { eqN("pctToLiq 20%", d, 20_000_000) };
  case null { Runtime.trap("FAIL: pctToLiq null") };
};
truth("pctToLiq null when liq null", MP.pctToLiq(10_000_000_000_000, null) == null);

// ── pool principal: deterministic + injective ──
truth("poolPrincipal deterministic", Principal.equal(MP.poolPrincipal(7), MP.poolPrincipal(7)));
truth("poolPrincipal distinct ids", not Principal.equal(MP.poolPrincipal(1), MP.poolPrincipal(2)));
truth("poolPrincipal distinct large", not Principal.equal(MP.poolPrincipal(1), MP.poolPrincipal(4294967297)));

Debug.print("── MarginPools.test: all passed ──");
