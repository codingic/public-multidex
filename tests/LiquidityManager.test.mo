// Pure-function unit tests for src/backend/lib/LiquidityManager.mo in integer
// base units (10^8) — validateNewOrder, the pre-trade risk gate. Pins: a valid
// order passes; buys are checked against SPENDABLE (available) cash, not raw
// balance; the minimum-order-value floor; the per-market 2.5× cap; and the
// sell-side asset/min checks. Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8.

import LM "../src/backend/lib/LiquidityManager";
import OB "../src/backend/lib/OrderBook";
import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
func isOk(r : { #ok; #err : Text }) : Bool { switch (r) { case (#ok) { true }; case (#err(_)) { false } } };
let alice = Principal.fromText("2vxsx-fae");
let mkt = "BTC-ICPUSD";
func px(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000_000 }; case (_) { null } } }; // $100000

Debug.print("── LiquidityManager.test ──");

// alice: 1000 ICPUSD + 5 BTC. Full availability (no locks).
let acc = Accounts.emptyState();
Accounts.setBalance(acc, alice, Types.QUOTE_TOKEN, 100_000_000_000); // 1000 ICPUSD
Accounts.setBalance(acc, alice, "BTC", 500_000_000);                // 5 BTC
let mg = ME.emptyState();
func availFull(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(acc, u, t) };
func availHalf(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(acc, u, t) / 2 };
let store = OB.emptyStore();

// ── BUY ── (price $100 = 10_000_000_000)
// valid: value 400 ≤ 1000 cash, ≥ min, within caps
truth("buy: valid → ok", isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 400_000_000)));
// insufficient: value 1500 > 1000 cash
truth("buy: insufficient cash → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 1_500_000_000)));
// below min: value 0.5 < 1.0
truth("buy: below min → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000, 500_000_000)));
// gated by AVAILABLE, not raw balance: value 600 ≤ balance(1000) but > available(500)
truth("buy: uses spendable not balance", not isOk(LM.validateNewOrder(store, acc, mg, px, availHalf, alice, mkt, "BTC", #buy, 10_000_000_000, 600_000_000)));

// per-market 2.5× cap: pre-stack a 2400-value buy; +200 → 2600 > 1000×2.5
let capStore = OB.emptyStore();
ignore OB.createOrder(capStore, mkt, alice, #buy, #limit, 10_000_000_000, 2_400_000_000, 1);
truth("buy: per-market 2.5× cap → err", not isOk(LM.validateNewOrder(capStore, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 200_000_000)));

// ── SELL ──
// valid: 3 BTC ≤ 5, value 300 ≥ min
truth("sell: valid → ok", isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 300_000_000)));
// insufficient asset: 10 > 5
truth("sell: insufficient asset → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 1_000_000_000)));
// below min: 0.001 × 100 = 0.1 < 1.0
truth("sell: below min → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 100_000)));

// ── adjustUserOrders: below-min cancel fallback must not underflow ──
// Regression (2026-07-09): the per-market shrink loop's below-MIN_ORDER
// fallback ran `excess -= orderValue` inside the branch where orderValue >
// excess is guaranteed — a certain Nat-underflow trap that rolled back the
// caller (the post-settlement sweep). Scenario: cap = 2.5 × $100 = $250;
// resting buys $85+$85+$73+$30 = $273 → excess $23; the newest ($30) order
// shrinks to $7 < $10 min → cancel path → excess must clamp to 0, not trap.
let adjAcc = Accounts.emptyState();
Accounts.setBalance(adjAcc, alice, Types.QUOTE_TOKEN, 10_000_000_000); // $100
let adjStore = OB.emptyStore();
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 1); // $85
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 2); // $85
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 73_000_000, 3); // $73
let newest = OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 30_000_000, 4); // $30 — walked first
func availAdj(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(adjAcc, u, t) };
let adjs = LM.adjustUserOrders(adjStore, adjAcc, mg, px, availAdj, alice, [(mkt, "BTC")], 5);
truth("adjust: below-min cancel fallback doesn't trap", adjs.size() > 0);
truth("adjust: sub-min order cancelled", switch (OB.getOrder(adjStore, newest.id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
truth("adjust: gross buy back under the 2.5x cap", OB.getUserMarketBuyTotal(adjStore, alice, mkt) <= 25_000_000_000);

Debug.print("── LiquidityManager.test PASSED ──");
