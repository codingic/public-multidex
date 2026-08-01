// Pure-function unit tests for src/backend/lib/MatchingEngine.mo in integer base
// units (10^8). Pins: an empty book fills nothing; a market buy walks resting
// asks best-price-first, produces the right trades + VWAP, fully settles both
// sides' balances; and the slippage cap stops the walk at the price bound. (The
// protected / deferred path is integration-exercised by the sim.)
// Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8; slippage frac ×10^8.

import MX "../src/backend/lib/MatchingEngine";
import OB "../src/backend/lib/OrderBook";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
let QUOTE = Types.QUOTE_TOKEN;
let mkt = "BTC-ICPUSD";
let base = "BTC";
let alice = Principal.fromText("2vxsx-fae"); // maker
let bob   = Principal.fromText("aaaaa-aa");   // taker

Debug.print("── MatchingEngine.test ──");

// ── Empty book → nothing fills ──
let s0 = OB.emptyStore();
let a0 = Accounts.emptyState();
Accounts.setBalance(a0, bob, QUOTE, 100_000_000_000);  // 1000 ICPUSD
let r0 = MX.executeMarketOrder(s0, a0, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 1); // buy 1 @ 10%
eqN("empty book: nothing filled", r0.totalFilled, 0);
eqN("empty book: remaining = qty", r0.remainingQty, 100_000_000);
truth("empty book: no trades", r0.trades.size() == 0);

// ── Market buy walks best-price-first; VWAP; full settlement ──
// Book: alice rests 2 BTC @ 100 and 1 BTC @ 101. bob buys 2.5 BTC @ 10% slippage.
let s = OB.emptyStore();
let acc = Accounts.emptyState();
Accounts.setBalance(acc, alice, base, 500_000_000);     // 5 BTC
Accounts.setBalance(acc, bob, QUOTE, 100_000_000_000);  // 1000 ICPUSD
ignore OB.createOrder(s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
ignore OB.createOrder(s, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2); // 1 @ 101
let r = MX.executeMarketOrder(s, acc, mkt, base, bob, #buy, 250_000_000, 10_000_000, false, 3); // buy 2.5 @ 10%
eqN("fill: totalFilled = 2.5", r.totalFilled, 250_000_000);
eqN("fill: VWAP = (2×100 + 0.5×101)/2.5 = 100.2", r.avgPrice, 10_020_000_000);
truth("fill: two trades (100 then 101)", r.trades.size() == 2);
eqN("fill: nothing left over", r.remainingQty, 0);
// settlement (cost = 2×100 + 0.5×101 = 250.5 = 25_050_000_000)
eqN("settle: bob received 2.5 BTC", Accounts.getBalance(acc, bob, base), 250_000_000);
eqN("settle: bob paid 250.5 ICPUSD", Accounts.getBalance(acc, bob, QUOTE), 100_000_000_000 - 25_050_000_000);
eqN("settle: alice delivered 2.5 BTC", Accounts.getBalance(acc, alice, base), 500_000_000 - 250_000_000);
eqN("settle: alice received 250.5 ICPUSD", Accounts.getBalance(acc, alice, QUOTE), 25_050_000_000);

// ── Slippage cap stops the walk ──
// Same book, but 0% slippage → maxPrice = best (100); the 101 level is skipped.
let s2 = OB.emptyStore();
let acc2 = Accounts.emptyState();
Accounts.setBalance(acc2, alice, base, 500_000_000);
Accounts.setBalance(acc2, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(s2, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1);
ignore OB.createOrder(s2, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2);
let r2 = MX.executeMarketOrder(s2, acc2, mkt, base, bob, #buy, 250_000_000, 0, false, 3); // 0% slippage
eqN("slippage 0: fills only the 100 level (2.0)", r2.totalFilled, 200_000_000);
eqN("slippage 0: 0.5 left unfilled", r2.remainingQty, 50_000_000);

// ════════════════════════════════════════════════════════════════════
// noPartialFill (fill-or-kill) pre-check — exercises simulateAvailableFill,
// which walks levelsByMarketSide best→worst and either confirms the FULL
// quantity is fillable or returns an empty result (kill) WITHOUT settling.
// Previously untested; pins the O(book) level-walk rewrite (was O(book²)).
// ════════════════════════════════════════════════════════════════════
Debug.print("── FOK / noPartialFill ──");

// A) KILL — insufficient depth: book holds 2 BTC, FOK wants 3 → kill, no settle.
let fa_s = OB.emptyStore();
let fa_a = Accounts.emptyState();
Accounts.setBalance(fa_a, alice, base, 500_000_000);          // 5 BTC maker
Accounts.setBalance(fa_a, bob, QUOTE, 100_000_000_000);       // 1000 ICPUSD taker (plenty)
ignore OB.createOrder(fa_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
let fa_r = MX.executeMarketOrder(fa_s, fa_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK kill (thin book): nothing filled", fa_r.totalFilled, 0);
eqN("FOK kill (thin book): remaining = full qty", fa_r.remainingQty, 300_000_000);
truth("FOK kill (thin book): no trades", fa_r.trades.size() == 0);
eqN("FOK kill: taker quote untouched", Accounts.getBalance(fa_a, bob, QUOTE), 100_000_000_000);
eqN("FOK kill: maker base untouched", Accounts.getBalance(fa_a, alice, base), 500_000_000);

// B) PASS — multi-level: 2 @ 100 + 2 @ 101, FOK 3 → fills across both levels.
let fb_s = OB.emptyStore();
let fb_a = Accounts.emptyState();
Accounts.setBalance(fb_a, alice, base, 500_000_000);
Accounts.setBalance(fb_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(fb_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
ignore OB.createOrder(fb_s, mkt, alice, #sell, #limit, 10_100_000_000, 200_000_000, 2); // 2 @ 101
let fb_r = MX.executeMarketOrder(fb_s, fb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 3); // FOK buy 3
eqN("FOK pass (multi-level): filled full 3", fb_r.totalFilled, 300_000_000);
eqN("FOK pass (multi-level): nothing left", fb_r.remainingQty, 0);
truth("FOK pass (multi-level): two trades", fb_r.trades.size() == 2);
eqN("FOK pass (multi-level): taker received 3 BTC", Accounts.getBalance(fb_a, bob, base), 300_000_000);

// C) KILL — slippage band hides deeper liquidity: 1 @ 100 + 5 @ 101, FOK 3 @ 0% slip.
let fc_s = OB.emptyStore();
let fc_a = Accounts.emptyState();
Accounts.setBalance(fc_a, alice, base, 1_000_000_000);
Accounts.setBalance(fc_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(fc_s, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1); // 1 @ 100
ignore OB.createOrder(fc_s, mkt, alice, #sell, #limit, 10_100_000_000, 500_000_000, 2); // 5 @ 101 (out of band)
let fc_r = MX.executeMarketOrder(fc_s, fc_a, mkt, base, bob, #buy, 300_000_000, 0, true, 3); // FOK buy 3 @ 0% slip
eqN("FOK kill (band): nothing filled", fc_r.totalFilled, 0);
truth("FOK kill (band): no trades", fc_r.trades.size() == 0);
eqN("FOK kill (band): taker quote untouched", Accounts.getBalance(fc_a, bob, QUOTE), 100_000_000_000);

// D) KILL — balance can't afford the FULL size: 5 @ 100, FOK 3, taker holds 250 (<300).
let fd_s = OB.emptyStore();
let fd_a = Accounts.emptyState();
Accounts.setBalance(fd_a, alice, base, 500_000_000);
Accounts.setBalance(fd_a, bob, QUOTE, 25_000_000_000);  // 250 ICPUSD (3@100 costs 300)
ignore OB.createOrder(fd_s, mkt, alice, #sell, #limit, 10_000_000_000, 500_000_000, 1); // 5 @ 100
let fd_r = MX.executeMarketOrder(fd_s, fd_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK kill (balance): nothing filled", fd_r.totalFilled, 0);
eqN("FOK kill (balance): taker quote untouched", Accounts.getBalance(fd_a, bob, QUOTE), 25_000_000_000);

// E) PASS — exact balance: 5 @ 100, FOK 3, taker holds exactly 300.
let fe_s = OB.emptyStore();
let fe_a = Accounts.emptyState();
Accounts.setBalance(fe_a, alice, base, 500_000_000);
Accounts.setBalance(fe_a, bob, QUOTE, 30_000_000_000);  // 300 ICPUSD exactly
ignore OB.createOrder(fe_s, mkt, alice, #sell, #limit, 10_000_000_000, 500_000_000, 1); // 5 @ 100
let fe_r = MX.executeMarketOrder(fe_s, fe_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK pass (exact balance): filled 3", fe_r.totalFilled, 300_000_000);
eqN("FOK pass (exact balance): taker spent all 300", Accounts.getBalance(fe_a, bob, QUOTE), 0);
eqN("FOK pass (exact balance): taker got 3 BTC", Accounts.getBalance(fe_a, bob, base), 300_000_000);

// F) KILL — sell-side FOK against thin bids (exercises the #sell / descending walk).
let ff_s = OB.emptyStore();
let ff_a = Accounts.emptyState();
Accounts.setBalance(ff_a, alice, QUOTE, 100_000_000_000);  // bid maker funded
Accounts.setBalance(ff_a, bob, base, 500_000_000);          // taker holds 5 BTC
ignore OB.createOrder(ff_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1); // bid 1 @ 100
let ff_r = MX.executeMarketOrder(ff_s, ff_a, mkt, base, bob, #sell, 300_000_000, 10_000_000, true, 2); // FOK sell 3
eqN("FOK sell kill (thin bids): nothing filled", ff_r.totalFilled, 0);
eqN("FOK sell kill: taker base untouched", Accounts.getBalance(ff_a, bob, base), 500_000_000);

// ════════════════════════════════════════════════════════════════════
// Symmetric maker/taker fee + self-trade prevention. The engine fees BOTH legs
// in QUOTE — buyer pays C+buyerFee, seller receives C-sellerFee, treasury gets
// both — keyed off MAKER(resting) vs TAKER(incoming), NOT buy/sell. STP makes a
// taker skip + cancel its OWN resting maker. Test rates: MAKER=5 bps, TAKER=10.
// ════════════════════════════════════════════════════════════════════
Debug.print("── symmetric maker/taker fee + STP ──");
let treas = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"); // stand-in treasury

// A ctx mirroring the real engine contract: quoteFee is PURE (role→bps→floor),
// creditTreasury skims the combined fee to `treas`, onSelfTrade cancels the
// resting self-maker (as cancelSelfMaker does in main.mo) and reports its id.
func mkFeeCtx(acc : Accounts.AccountState, store : OB.OrderStore, onCancel : (Nat) -> ()) : MX.ProtectionCtx = {
  getMakerWindow   = func(_) { 0 };
  getMakerPending  = func(_) { 0 };
  availableBalance = func(p, t) { Accounts.getBalance(acc, p, t) };
  isNonTakeable    = func(_, _) { false };
  isExpired        = func(_) { false };
  onPendingFill    = func(_, _, _, _, _, _, _) { null };
  quoteFee         = func(_p, gross, role) {
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000   // floor — == Fixed.mulDiv(gross, bps, 10_000, false)
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(acc, treas, QUOTE, fee) } };
  onSelfTrade      = func(id, _owner) { ignore OB.cancelOrder(store, id); onCancel(id) };
  onTradeFees      = func(_, _, _) {};
};

// ── (1) BUY fill: taker=buyer pays TAKER(10 bps); maker=seller pays MAKER(5 bps).
//        Buyer funded with EXACTLY C+takerFee (zero headroom) — pins the
//        reservation/affordability gate. C=100 ICPUSD=10_000_000_000. ──
let sb_s = OB.emptyStore();
let sb_a = Accounts.emptyState();
Accounts.setBalance(sb_a, alice, base, 100_000_000);            // 1 BTC maker (seller)
Accounts.setBalance(sb_a, bob, QUOTE, 10_010_000_000);          // C + takerFee, ZERO headroom
ignore OB.createOrder(sb_s, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let sb_before = Accounts.getBalance(sb_a, alice, QUOTE) + Accounts.getBalance(sb_a, bob, QUOTE) + Accounts.getBalance(sb_a, treas, QUOTE);
let sb_r = MX.executeMarketOrderProtected(sb_s, sb_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 2, mkFeeCtx(sb_a, sb_s, func(_) {}));
eqN("buyfee: filled 1 BTC at zero headroom (gate holds)", sb_r.totalFilled, 100_000_000);
eqN("buyfee: buyer paid C+takerFee → 0", Accounts.getBalance(sb_a, bob, QUOTE), 0);
eqN("buyfee: buyer got 1 BTC", Accounts.getBalance(sb_a, bob, base), 100_000_000);
eqN("buyfee: seller got C-makerFee (9_995_000_000)", Accounts.getBalance(sb_a, alice, QUOTE), 9_995_000_000);
eqN("buyfee: treasury got takerFee+makerFee (15_000_000)", Accounts.getBalance(sb_a, treas, QUOTE), 15_000_000);
eqN("buyfee: Σ QUOTE conserved", Accounts.getBalance(sb_a, alice, QUOTE) + Accounts.getBalance(sb_a, bob, QUOTE) + Accounts.getBalance(sb_a, treas, QUOTE), sb_before);

// ── (2) SELL fill: rate keys off ROLE, NOT side. taker=seller pays TAKER(10);
//        maker=buyer pays MAKER(5). The maker-buyer's QUOTE debit is C+makerFee. ──
let fs_s = OB.emptyStore();
let fs_a = Accounts.emptyState();
Accounts.setBalance(fs_a, alice, QUOTE, 10_005_000_000);        // maker buyer: C + makerFee
Accounts.setBalance(fs_a, bob, base, 100_000_000);             // taker seller: 1 BTC
ignore OB.createOrder(fs_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1);
let fs_before = Accounts.getBalance(fs_a, alice, QUOTE) + Accounts.getBalance(fs_a, bob, QUOTE) + Accounts.getBalance(fs_a, treas, QUOTE);
let fs_r = MX.executeMarketOrderProtected(fs_s, fs_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, false, 3, mkFeeCtx(fs_a, fs_s, func(_) {}));
eqN("sellfee: filled 1 BTC", fs_r.totalFilled, 100_000_000);
eqN("sellfee: maker-buyer paid C+makerFee → 0", Accounts.getBalance(fs_a, alice, QUOTE), 0);
eqN("sellfee: maker-buyer got 1 BTC", Accounts.getBalance(fs_a, alice, base), 100_000_000);
eqN("sellfee: taker-seller got C-takerFee (9_990_000_000)", Accounts.getBalance(fs_a, bob, QUOTE), 9_990_000_000);
eqN("sellfee: treasury got makerFee+takerFee (15_000_000)", Accounts.getBalance(fs_a, treas, QUOTE), 15_000_000);
eqN("sellfee: Σ QUOTE conserved", Accounts.getBalance(fs_a, alice, QUOTE) + Accounts.getBalance(fs_a, bob, QUOTE) + Accounts.getBalance(fs_a, treas, QUOTE), fs_before);

// ── (3) Self-trade prevention: alice market-sells into her OWN resting bid →
//        no fill, the resting bid is cancelled, her balances are untouched. ──
let st_s = OB.emptyStore();
let st_a = Accounts.emptyState();
Accounts.setBalance(st_a, alice, QUOTE, 10_005_000_000);        // funds her resting bid
Accounts.setBalance(st_a, alice, base, 100_000_000);           // and the base she'd sell
let st_bid = OB.createOrder(st_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1);
var st_cancelled : Nat = 0;
let st_r = MX.executeMarketOrderProtected(st_s, st_a, mkt, base, alice, #sell, 100_000_000, 10_000_000, false, 4, mkFeeCtx(st_a, st_s, func(id) { st_cancelled := id }));
eqN("stp: no self-fill (totalFilled 0)", st_r.totalFilled, 0);
truth("stp: no trade recorded", st_r.trades.size() == 0);
eqN("stp: onSelfTrade cancelled the resting bid", st_cancelled, st_bid.id);
eqN("stp: alice QUOTE untouched", Accounts.getBalance(st_a, alice, QUOTE), 10_005_000_000);
eqN("stp: alice base untouched", Accounts.getBalance(st_a, alice, base), 100_000_000);

// ── (4) EXEMPT counterparty (the pool-vs-AMM case): a fee-bearing taker buys from
//        an EXEMPT maker (AMM/insurance/treasury). Only the taker leg is fee'd — the
//        exempt seller keeps the FULL tradeCost, treasury gets just the taker fee.
//        This is what un-exempting margin pools relies on: a pool buying AMM
//        liquidity pays its fee while the AMM's economics are untouched. (Both-non-
//        exempt — pool-vs-user / pool-vs-pool — is the buyfee/sellfee case above.) ──
let ex_s = OB.emptyStore();
let ex_a = Accounts.emptyState();
let ammP = Principal.fromText("mxzaz-hqaaa-aaaar-qaada-cai");  // stand-in EXEMPT principal (AMM)
Accounts.setBalance(ex_a, ammP, base, 100_000_000);            // exempt maker (seller)
Accounts.setBalance(ex_a, bob, QUOTE, 10_010_000_000);         // taker (buyer): C + takerFee
ignore OB.createOrder(ex_s, mkt, ammP, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let ex_ctx : MX.ProtectionCtx = {
  getMakerWindow   = func(_) { 0 };
  getMakerPending  = func(_) { 0 };
  availableBalance = func(p, t) { Accounts.getBalance(ex_a, p, t) };
  isNonTakeable    = func(_, _) { false };
  isExpired        = func(_) { false };
  onPendingFill    = func(_, _, _, _, _, _, _) { null };
  quoteFee         = func(p, gross, role) {
    if (Principal.equal(p, ammP)) { return 0 };   // exempt party → no fee on its leg
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(ex_a, treas, QUOTE, fee) } };
  onSelfTrade      = func(_, _) {};
  onTradeFees      = func(_, _, _) {};
};
let ex_before = Accounts.getBalance(ex_a, ammP, QUOTE) + Accounts.getBalance(ex_a, bob, QUOTE) + Accounts.getBalance(ex_a, treas, QUOTE);
let ex_r = MX.executeMarketOrderProtected(ex_s, ex_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 5, ex_ctx);
eqN("exempt-cpty: filled 1 BTC", ex_r.totalFilled, 100_000_000);
eqN("exempt-cpty: taker paid C+takerFee → 0", Accounts.getBalance(ex_a, bob, QUOTE), 0);
eqN("exempt-cpty: AMM seller kept FULL tradeCost (no maker fee)", Accounts.getBalance(ex_a, ammP, QUOTE), 10_000_000_000);
eqN("exempt-cpty: treasury got ONLY the taker fee (10_000_000)", Accounts.getBalance(ex_a, treas, QUOTE), 10_000_000);
eqN("exempt-cpty: Σ QUOTE conserved", Accounts.getBalance(ex_a, ammP, QUOTE) + Accounts.getBalance(ex_a, bob, QUOTE) + Accounts.getBalance(ex_a, treas, QUOTE), ex_before);

// ── (5) Origin-type threading + IOC market releases (the Calm-Bear-91 bug):
//        a #market execution must (a) stamp takerOrderType = #market on its
//        trades, (b) return a #market order record covering ONLY the filled
//        portion (closed, never resting), and (c) leave NO remainder on the
//        book — the caller re-defers it. A dry #market cycle records nothing.
//        #limit keeps the resting behavior. ──
let io_s = OB.emptyStore();
let io_a = Accounts.emptyState();
Accounts.setBalance(io_a, alice, base, 50_000_000);              // maker: 0.5 BTC
Accounts.setBalance(io_a, bob, QUOTE, 100_000_000_000);          // taker: 1000 ICPUSD
ignore OB.createOrder(io_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1); // 0.5 @ 100
let (io_o, io_t, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #market, 11_000_000_000, 200_000_000, 2, 2, // MARKET buy 2, cap 110
  mkFeeCtx(io_a, io_s, func(_) {})
);
truth("IOC: trade stamped takerOrderType = #market", io_t.size() == 1 and io_t[0].takerOrderType == ?#market);
truth("IOC: returned order is #market", io_o.orderType == #market);
eqN("IOC: order records ONLY the filled portion", io_o.quantity, 50_000_000);
eqN("IOC: order.filled = filled portion (caller derives remainder)", io_o.filled, 50_000_000);
truth("IOC: order is CLOSED (#filled), never resting", io_o.status == #filled);
truth("IOC: NO remainder resting on the book (no bid appeared)",
  OB.findBestMatch(io_s, mkt, #sell) == null);   // a seller would match the best BID — none

// Dry market cycle: nothing filled → synthetic id-0 record, store untouched.
let (dry_o, dry_t, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #market, 11_000_000_000, 100_000_000, 3, 3,
  mkFeeCtx(io_a, io_s, func(_) {})
);
truth("IOC dry: no trades", dry_t.size() == 0);
eqN("IOC dry: synthetic id 0 (never enters the store)", dry_o.id, 0);
truth("IOC dry: nothing recorded in the store", OB.getOrder(io_s, 0) == null);

// Control: a #limit execution with a remainder still RESTS (unchanged semantics).
let (lm_o, _, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #limit, 9_000_000_000, 100_000_000, 4, 4,  // passive bid @ 90
  mkFeeCtx(io_a, io_s, func(_) {})
);
truth("limit control: remainder rests open", lm_o.status == #open and lm_o.orderType == #limit);
truth("limit control: resting bid IS on the book",
  OB.findBestMatch(io_s, mkt, #sell) != null);

// ── Two clocks: the order record keeps the SUBMISSION timestamp, the trades
//    it produces stamp at SETTLEMENT. This is the deferred-release contract —
//    a staged order releasing 15s after submission must not mint trades born
//    15s old (the Trades feed read permanently stale on users-only markets,
//    and fills landed in already-closed candle buckets). ──
let tc_s = OB.emptyStore();
let tc_a = Accounts.emptyState();
Accounts.setBalance(tc_a, alice, base, 50_000_000);
Accounts.setBalance(tc_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(tc_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 100);
let (tc_o, tc_t, _, _) = MX.executeLimitOrderProtected(
  tc_s, tc_a, mkt, base, bob, #buy, #limit, 10_000_000_000, 50_000_000,
  1_000, 16_000, // submitted at t=1000, SETTLES at t=16000 (a 15s users-only walk)
  mkFeeCtx(tc_a, tc_s, func(_) {})
);
truth("two clocks: trade stamped at SETTLEMENT time", tc_t.size() == 1 and tc_t[0].timestamp == 16_000);
truth("two clocks: order record keeps the SUBMISSION time", tc_o.timestamp == 1_000);
// Legacy wrapper: one clock in → both records agree (synchronous semantics).
let lw_s = OB.emptyStore();
let lw_a = Accounts.emptyState();
Accounts.setBalance(lw_a, alice, base, 50_000_000);
Accounts.setBalance(lw_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(lw_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 100);
let (lw_o, lw_t, _, _) = MX.executeLimitOrder(
  lw_s, lw_a, mkt, base, bob, #buy, 10_000_000_000, 50_000_000, 7_777
);
truth("legacy wrapper: one clock stamps both order and trade",
  lw_o.timestamp == 7_777 and lw_t.size() == 1 and lw_t[0].timestamp == 7_777);

Debug.print("── MatchingEngine.test PASSED ──");
