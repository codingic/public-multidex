// Pure-function unit tests for src/backend/lib/OrderBook.mo in integer base
// units (10^8). Pins createOrder fields, remaining/isOpen, partial vs full fill
// (status + index removal), findBestMatch returning the best price (lowest ask /
// highest bid) with time priority inside a level, cancel removing an order, and
// getUserOpenOrders isolation. Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8.

import OB "../src/backend/lib/OrderBook";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Option "mo:core/Option";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

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

// ════════════════════════════════════════════════════════════════════
// Secondary-index PRUNING. removeFromOpenIndexes used to delete the order id
// from the user's inner set but leave the (now empty) OUTER entry behind, so
// openOrdersByUser retained one entry per principal that had EVER placed an
// order — unbounded growth in the upgrade-carried heap, and an ever-longer
// full-map walk for main.mo's sweepStaleUserOrders and tickTier, which both
// iterate it whole. The leak was invisible through the public accessors: they
// all report the same 0/[] for "absent" and "present but empty", so these
// tests read the raw index. The price-level index, which already pruned
// correctly, is re-pinned below as the regression guard.
// ════════════════════════════════════════════════════════════════════
Debug.print("── open-index pruning ──");

// Does the raw index still hold an OUTER entry for this principal? Distinct
// from "has open orders" — a leaked entry is an empty inner set.
func hasUserIndexEntry(store : OB.OrderStore, p : Principal) : Bool {
  Option.isSome(Map.get(store.openOrdersByUser, Text.compare, Principal.toText(p)));
};
func hasPriceLevel(store : OB.OrderStore, side : Types.Side, price : Nat) : Bool {
  switch (Map.get(store.levelsByMarketSide, Text.compare, OB.marketSideKey(mkt, side))) {
    case null { false };
    case (?lvls) { Option.isSome(Map.get(lvls, Nat.compare, price)) };
  };
};

// ── the leak proof: a user's only order, placed then removed ──
let ix = OB.emptyStore();
let x1 = OB.createOrder(ix, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
truth("user index: entry appears when the order is placed", hasUserIndexEntry(ix, alice));
truth("user index: a principal who never ordered has no entry", not hasUserIndexEntry(ix, bob));
ignore OB.cancelOrder(ix, x1.id);
truth("user index: alice has no open orders after the cancel", OB.getUserOpenOrders(ix, alice).size() == 0);
truth("user index: NO residual entry once the user's only order leaves", not hasUserIndexEntry(ix, alice));

// ── two orders: the entry survives the first removal, goes on the second ──
let ix2 = OB.emptyStore();
let y1 = OB.createOrder(ix2, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let y2 = OB.createOrder(ix2, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2);
ignore OB.cancelOrder(ix2, y1.id);
truth("user index: entry KEPT while a second order still rests", hasUserIndexEntry(ix2, alice));
eqN("user index: ...holding exactly the surviving order", OB.getUserOpenOrders(ix2, alice).size(), 1);
eqN("user index: ...and the count agrees", OB.getUserOpenOrderCount(ix2, alice), 1);
ignore OB.cancelOrder(ix2, y2.id);
truth("user index: entry pruned only after the LAST order leaves", not hasUserIndexEntry(ix2, alice));
eqN("user index: count reads 0 through the pruned entry", OB.getUserOpenOrderCount(ix2, alice), 0);
truth("user index: oldest-open-id reads null through the pruned entry", Option.isNull(OB.getOldestOpenOrderId(ix2, alice)));

// ── a FULL FILL closes through the same path, so it prunes too ──
let ix3 = OB.emptyStore();
let z1 = OB.createOrder(ix3, mkt, bob, #buy, #limit, 10_000_000_000, 100_000_000, 1);
ignore OB.fillOrder(ix3, z1.id, 50_000_000);
truth("user index: partial fill keeps the entry (the order still rests)", hasUserIndexEntry(ix3, bob));
ignore OB.fillOrder(ix3, z1.id, 50_000_000);
truth("user index: full fill prunes the entry", not hasUserIndexEntry(ix3, bob));

// ── one user's churn never disturbs another's entry ──
let ix4 = OB.emptyStore();
let w1 = OB.createOrder(ix4, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
ignore OB.createOrder(ix4, mkt, bob, #buy, #limit, 9_900_000_000, 100_000_000, 2);
ignore OB.cancelOrder(ix4, w1.id);
truth("user index: alice pruned", not hasUserIndexEntry(ix4, alice));
truth("user index: bob's entry untouched", hasUserIndexEntry(ix4, bob));
eqN("user index: bob still reads his open order", OB.getUserOpenOrders(ix4, bob).size(), 1);

// ── regression guard: price-level pruning still behaves as before ──
let lv = OB.emptyStore();
let l1 = OB.createOrder(lv, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let l2 = OB.createOrder(lv, mkt, bob,   #sell, #limit, 10_000_000_000, 100_000_000, 2); // same level
let l3 = OB.createOrder(lv, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 3); // other level
truth("levels: both price levels present", hasPriceLevel(lv, #sell, 10_000_000_000) and hasPriceLevel(lv, #sell, 10_100_000_000));
ignore OB.cancelOrder(lv, l1.id);
truth("levels: level KEPT while another order rests at that price", hasPriceLevel(lv, #sell, 10_000_000_000));
ignore OB.cancelOrder(lv, l2.id);
truth("levels: level pruned once its last order leaves", not hasPriceLevel(lv, #sell, 10_000_000_000));
truth("levels: the untouched level is unaffected", hasPriceLevel(lv, #sell, 10_100_000_000));
switch (OB.findBestMatch(lv, mkt, #buy)) {
  case (?b) { eqN("levels: best match skips the pruned level", b.price, 10_100_000_000) };
  case null { Runtime.trap("FAIL: levels: best match vanished while an ask still rests") };
};
ignore OB.cancelOrder(lv, l3.id);
truth("levels: last level pruned too", not hasPriceLevel(lv, #sell, 10_100_000_000));
truth("levels: empty book has no best match", Option.isNull(OB.findBestMatch(lv, mkt, #buy)));

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

// ════════════════════════════════════════════════════════════════════
// (timestamp, id) LEVEL KEYS. The inner level sets are keyed by
// (timestamp, id) so the FIRST entry is the time-priority head and
// findBestMatchExcluding reads it in O(log K) instead of walking all K
// same-price orders per call — the O(K²) sweep shape that let ~3k orders
// stacked at one price trap the instruction limit. These tests pin that the
// ENCODED order is the book's real priority: submission timestamp first
// (id order genuinely diverges — a staged order rests under a fresh id but
// keeps its submission stamp), id as the tie-break, and that removal,
// exclusion and the migration's rebuild all preserve it exactly.
// ════════════════════════════════════════════════════════════════════
Debug.print("── (timestamp, id) level keys ──");

// Insertion order ≠ id order ≠ time order: the head must follow TIME.
let tk = OB.emptyStore();
let tkLate  = OB.createOrder(tk, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 10); // id 1, ts 10
let tkFirst = OB.createOrder(tk, mkt, bob,   #sell, #limit, 10_000_000_000, 100_000_000, 5);  // id 2, ts 5
let tkMid   = OB.createOrder(tk, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 7);  // id 3, ts 7
switch (OB.findBestMatch(tk, mkt, #buy)) {
  case (?b) { truth("level keys: head = earliest ts despite higher id", b.id == tkFirst.id) };
  case null { Runtime.trap("no head at populated level") };
};
// Excluding the head advances to the second-by-TIME, not by id.
let excl = Map.empty<Nat, Bool>();
Map.add(excl, Nat.compare, tkFirst.id, true);
switch (OB.findBestMatchExcluding(tk, mkt, #buy, ?excl)) {
  case (?b) { truth("level keys: excluded head → second-by-time (ts 7)", b.id == tkMid.id) };
  case null { Runtime.trap("no match with head excluded") };
};
ignore OB.cancelOrder(tk, tkFirst.id);
switch (OB.findBestMatch(tk, mkt, #buy)) {
  case (?b) { truth("level keys: cancelled head → next-by-time (ts 7)", b.id == tkMid.id) };
  case null { Runtime.trap("no head after cancel") };
};
ignore OB.cancelOrder(tk, tkMid.id);
switch (OB.findBestMatch(tk, mkt, #buy)) {
  case (?b) { truth("level keys: …then the latest (ts 10)", b.id == tkLate.id) };
  case null { Runtime.trap("no head after second cancel") };
};

// Equal timestamps → id is the tie-break (earlier placement wins).
let tb = OB.emptyStore();
let tbA  = OB.createOrder(tb, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 42);
let _tbB = OB.createOrder(tb, mkt, bob,   #sell, #limit, 10_000_000_000, 100_000_000, 42);
switch (OB.findBestMatch(tb, mkt, #buy)) {
  case (?b) { truth("level keys: same ts → lower id wins", b.id == tbA.id) };
  case null { Runtime.trap("no head at tie level") };
};

// ── getLevelOrderCount: the per-price resting count the placement cap reads ──
let lc = OB.emptyStore();
eqN("level count: empty = 0", OB.getLevelOrderCount(lc, mkt, #sell, 10_000_000_000), 0);
let lc1 = OB.createOrder(lc, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1);
ignore OB.createOrder(lc, mkt, bob,   #sell, #limit, 10_000_000_000, 100_000_000, 2);
ignore OB.createOrder(lc, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 3);
eqN("level count: two rest at this price", OB.getLevelOrderCount(lc, mkt, #sell, 10_000_000_000), 2);
eqN("level count: the other level counts its own", OB.getLevelOrderCount(lc, mkt, #sell, 10_100_000_000), 1);
eqN("level count: sides are independent", OB.getLevelOrderCount(lc, mkt, #buy, 10_000_000_000), 0);
ignore OB.fillOrder(lc, lc1.id, 100_000_000);
eqN("level count: partial fill keeps the order counted", OB.getLevelOrderCount(lc, mkt, #sell, 10_000_000_000), 2);
ignore OB.fillOrder(lc, lc1.id, 100_000_000);
eqN("level count: full fill releases its slot", OB.getLevelOrderCount(lc, mkt, #sell, 10_000_000_000), 1);

// ── rebuildLevelIndex: the migration's reconstruction is exact ──
// Simulate the post-upgrade state the one-shot migration starts from: level
// maps emptied, all master data intact — rebuild, then confirm price walk,
// time priority and pruning behave as if the index had never been away.
let rb = OB.emptyStore();
let rb1 = OB.createOrder(rb, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 9);
let rb2 = OB.createOrder(rb, mkt, bob,   #sell, #limit, 10_000_000_000, 100_000_000, 4); // later id, EARLIER ts
let rb3 = OB.createOrder(rb, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 6);
let rb4 = OB.createOrder(rb, mkt, bob,   #buy,  #limit,  9_900_000_000, 100_000_000, 7);
ignore OB.cancelOrder(rb, rb3.id);            // a closed order must NOT come back
Map.clear(rb.levelsByMarketSide);             // ← what the migration starts from
truth("rebuild: index really is empty", Option.isNull(OB.findBestMatch(rb, mkt, #buy)));
OB.rebuildLevelIndex(rb);
switch (OB.findBestMatch(rb, mkt, #buy)) {
  case (?b) { truth("rebuild: ask head = earliest ts at best price", b.id == rb2.id) };
  case null { Runtime.trap("rebuild lost the asks") };
};
switch (OB.findBestMatch(rb, mkt, #sell)) {
  case (?b) { truth("rebuild: bid side restored", b.id == rb4.id) };
  case null { Runtime.trap("rebuild lost the bids") };
};
truth("rebuild: cancelled order's level stays absent", not hasPriceLevel(rb, #sell, 10_100_000_000));
ignore OB.cancelOrder(rb, rb1.id);
ignore OB.cancelOrder(rb, rb2.id);
truth("rebuild: rebuilt level prunes clean on last removal", not hasPriceLevel(rb, #sell, 10_000_000_000));

Debug.print("── OrderBook.test PASSED ──");
