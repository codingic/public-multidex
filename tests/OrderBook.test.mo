// Pure-function unit tests for src/backend/lib/OrderBook.mo in integer base
// units (10^8). Pins createOrder fields, remaining/isOpen, partial vs full fill
// (status + index removal), findBestMatch returning the best price (lowest ask /
// highest bid) with time priority inside a level, cancel removing an order, and
// getUserOpenOrders isolation. Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8.

import OB "../src/backend/lib/OrderBook";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Option "mo:core/Option";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
let mkt = "BTC-ICPUSD";
let alice = Principal.fromText("2vxsx-fae");
let bob   = Principal.fromText("aaaaa-aa");

Debug.print("── OrderBook.test ──");

// ── createOrder / remaining / isOpen ── ($100, 2 units)
let s = OB.emptyStore();
let o1 = OB.createOrder(s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1);
truth("createOrder: open", OB.isOpen(o1));
eqN("createOrder: filled = 0", o1.filled, 0);
eqN("createOrder: remaining = qty", OB.remaining(o1), 200_000_000);
eqN("createOrder: originalQuantity = qty", o1.originalQuantity, 200_000_000);
let o2 = OB.createOrder(s, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2);
truth("createOrder: ids increment", o2.id == o1.id + 1);

// ── fillOrder: partial keeps it open, full closes + removes from index ──
switch (OB.fillOrder(s, o1.id, 50_000_000)) {       // fill 0.5
  case (?u) {
    eqN("fill partial: filled", u.filled, 50_000_000);
    eqN("fill partial: remaining", OB.remaining(u), 150_000_000);
    truth("fill partial: still open", OB.isOpen(u));
  };
  case null { Runtime.trap("fillOrder partial returned null") };
};
switch (OB.fillOrder(s, o1.id, 150_000_000)) {      // fill remaining 1.5
  case (?u) {
    eqN("fill full: filled = qty", u.filled, 200_000_000);
    truth("fill full: remaining 0", OB.remaining(u) == 0);
    truth("fill full: not open", not OB.isOpen(u));
  };
  case null { Runtime.trap("fillOrder full returned null") };
};

// ── findBestMatch: best PRICE (lowest ask for a buy taker) ──
let pf = OB.emptyStore();
ignore OB.createOrder(pf, mkt, alice, #sell, #limit, 10_200_000_000, 100_000_000, 1);
let lowAsk = OB.createOrder(pf, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 2);
ignore OB.createOrder(pf, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 3);
switch (OB.findBestMatch(pf, mkt, #buy)) {
  case (?b) { eqN("buy taker → lowest ask = 100", b.price, 10_000_000_000); truth("...and it's that order", b.id == lowAsk.id) };
  case null { Runtime.trap("no best match for buy taker") };
};

// highest bid for a sell taker
let bf = OB.emptyStore();
ignore OB.createOrder(bf, mkt, bob, #buy, #limit, 9_800_000_000, 100_000_000, 1);
let hiBid = OB.createOrder(bf, mkt, bob, #buy, #limit, 10_000_000_000, 100_000_000, 2);
ignore OB.createOrder(bf, mkt, bob, #buy, #limit, 9_900_000_000, 100_000_000, 3);
switch (OB.findBestMatch(bf, mkt, #sell)) {
  case (?b) { eqN("sell taker → highest bid = 100", b.price, 10_000_000_000); truth("...and it's that order", b.id == hiBid.id) };
  case null { Runtime.trap("no best match for sell taker") };
};

// ── time priority within a price level: earliest timestamp wins ──
let tf = OB.emptyStore();
ignore OB.createOrder(tf, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 10); // later
let earlier = OB.createOrder(tf, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 5); // earlier ts
switch (OB.findBestMatch(tf, mkt, #buy)) {
  case (?b) { truth("same price → earliest timestamp wins", b.id == earlier.id) };
  case null { Runtime.trap("no best match (time-priority)") };
};

// ── cancelOrder removes it from the book ──
let cf = OB.emptyStore();
let c1 = OB.createOrder(cf, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
ignore OB.cancelOrder(cf, c1.id);
switch (OB.getOrder(cf, c1.id)) { case (?o) { truth("cancel: not open", not OB.isOpen(o)) }; case null { Runtime.trap("cancelled order vanished from store") } };
truth("cancel: no longer matchable", Option.isNull(OB.findBestMatch(cf, mkt, #buy)));

// ── sideEq ──
truth("sideEq buy/buy", OB.sideEq(#buy, #buy));
truth("sideEq sell/sell", OB.sideEq(#sell, #sell));
truth("sideEq buy/sell = false", not OB.sideEq(#buy, #sell));

// ── getUserOpenOrders isolation ──
let uf = OB.emptyStore();
ignore OB.createOrder(uf, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
ignore OB.createOrder(uf, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2);
ignore OB.createOrder(uf, mkt, bob, #buy, #limit, 9_900_000_000, 100_000_000, 3);
truth("getUserOpenOrders: alice has 2", OB.getUserOpenOrders(uf, alice).size() == 2);
truth("getUserOpenOrders: bob has 1", OB.getUserOpenOrders(uf, bob).size() == 1);

// ── fillEmptyCandles: zero-volume price continuity ──
// A tradeless bucket gets a flat candle at the given price with volume = 0;
// a bucket that trades is never touched; retention pruning runs on insert.
let kf = OB.emptyStore();
let minuteNs : Int = 60_000_000_000;
let t0 : Int = 1_000_000 * minuteNs;   // aligned bucket start
// empty market + sweep → synthetic candle at the reference price
OB.fillEmptyCandles(kf, mkt, 10_000_000_000, t0 + 1);
let cr1 = OB.getCandles(kf, mkt, 60000, 0, 10);
eqN("fill: one candle minted in empty market", cr1.candles.size(), 1);
eqN("fill: open = ref price", cr1.candles[0].open, 10_000_000_000);
eqN("fill: close = ref price", cr1.candles[0].close, 10_000_000_000);
eqN("fill: volume = 0 (synthetic marker)", cr1.candles[0].volume, 0);
// same bucket, second sweep → still exactly one candle (upsert-if-absent)
OB.fillEmptyCandles(kf, mkt, 10_500_000_000, t0 + 2);
eqN("fill: idempotent within a bucket", OB.getCandles(kf, mkt, 60000, 0, 10).candles.size(), 1);
eqN("fill: existing candle not repriced", OB.getCandles(kf, mkt, 60000, 0, 10).candles[0].close, 10_000_000_000);
// a bucket with a real trade is never touched by the sweep
let tradeBucket : Int = t0 + minuteNs;   // next minute
ignore OB.recordTrade(kf, mkt, 1, 2, alice, bob, 12_000_000_000, 300_000_000, tradeBucket + 5, null);
OB.fillEmptyCandles(kf, mkt, 9_000_000_000, tradeBucket + 6);
let cr2 = OB.getCandles(kf, mkt, 60000, 0, 10);
eqN("fill: traded bucket keeps trade close", cr2.candles[1].close, 12_000_000_000);
eqN("fill: traded bucket keeps trade volume", cr2.candles[1].volume, 300_000_000);
// a later real trade takes over a synthetic bucket (open stays the ref price)
let b3 : Int = t0 + 2 * minuteNs;
OB.fillEmptyCandles(kf, mkt, 11_000_000_000, b3 + 1);
ignore OB.recordTrade(kf, mkt, 3, 4, alice, bob, 11_500_000_000, 100_000_000, b3 + 10, null);
let cr3 = OB.getCandles(kf, mkt, 60000, 0, 10);
eqN("fill: trade into synthetic bucket — open stays ref", cr3.candles[2].open, 11_000_000_000);
eqN("fill: trade into synthetic bucket — close is trade", cr3.candles[2].close, 11_500_000_000);
eqN("fill: trade into synthetic bucket — volume real", cr3.candles[2].volume, 100_000_000);
// retention: 1m candles older than 120h are pruned on the next insert
let far : Int = t0 + 433_000 * 1_000_000_000;   // > 120h (432_000s) later
OB.fillEmptyCandles(kf, mkt, 10_000_000_000, far);
let cr4 = OB.getCandles(kf, mkt, 60000, 0, 10);
truth("fill: retention pruned the old 1m candles", cr4.candles.size() <= 2);

Debug.print("── OrderBook.test PASSED ──");
