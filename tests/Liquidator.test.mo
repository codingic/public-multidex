// Pure-function unit tests for src/backend/lib/Liquidator.mo in integer base
// units (10^8) — the single most money-critical path. Pins: the race-safe no-op
// on a healthy user, the planLiquidation decision, an end-to-end liquidation's
// INVARIANTS (debt down, health restored above maintenance, collateral moved to
// the vault, penalty kept — asserted as properties), and the internally-netted
// long↔short settlement (deterministic, exact).

import LQ "../src/backend/lib/Liquidator";
import BE "../src/backend/lib/BorrowEngine";
import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
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
let QUOTE = Types.QUOTE_TOKEN;
let vault = Principal.fromText("aaaaa-aa");
let alice = Principal.fromText("2vxsx-fae");
let bob   = Principal.fromText("tz2ag-zx777-77776-aaabq-cai");

func px(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000_000 }; case (_) { null } } };  // $100000
func pxCrash(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?500_000_000_000 }; case (_) { null } } }; // $5000
func noReserved(_ : Principal, _ : Types.TokenId) : Nat { 0 };

// alice: 1 BTC collateral, 40k ICPUSD borrowed (healthy at BTC=100k).
func liquidatableAlice() : (BE.LoanState, ME.MarginState, Accounts.AccountState) {
  let st = BE.emptyState(); let mg = ME.emptyState(); let acc = Accounts.emptyState();
  Accounts.setBalance(acc, vault, QUOTE, 100_000_000_000_000);  // 1,000,000 ICPUSD
  switch (ME.open(mg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
  Accounts.setBalance(acc, alice, "BTC", 100_000_000);          // 1 BTC
  switch (BE.borrow(st, mg, acc, noReserved, vault, alice, QUOTE, 4_000_000_000_000, 0, px)) { // 40000
    case (#ok(_)) {}; case (#err(e)) { Runtime.trap("setup borrow: " # e) };
  };
  (st, mg, acc);
};

Debug.print("── Liquidator.test ──");

// ── Healthy user: no-op (#healthy) and no plan ──
let (st0, mg0, acc0) = liquidatableAlice();
switch (LQ.tryLiquidate(st0, mg0, acc0, noReserved, alice, vault, 1, px)) {
  case (#healthy) { Debug.print("  ✓ healthy user → #healthy no-op") };
  case (_) { Runtime.trap("FAIL: liquidated a healthy user") };
};
truth("planLiquidation: null when healthy", Option.isNull(LQ.planLiquidation(st0, mg0, acc0, noReserved, alice, px)));

// ── Crash BTC 100k→5k → alice liquidatable ──
let (st, mg, acc) = liquidatableAlice();
let hBefore = BE.getHealth(st, mg, acc, noReserved, alice, pxCrash);
truth("setup: liquidatable after crash", hBefore.isLiquidatable);

switch (LQ.planLiquidation(st, mg, acc, noReserved, alice, pxCrash)) {
  case (?plan) {
    truth("plan: targets ICPUSD debt", plan.debtToken == QUOTE);
    truth("plan: seize qty > 0", plan.seizeQty > 0);
  };
  case null { Runtime.trap("FAIL: no plan for a liquidatable user") };
};

let debtBefore  = BE.loanOf(st, alice, QUOTE);
let aliceBefore = Accounts.getBalance(acc, alice, QUOTE);
let vaultBefore = Accounts.getBalance(acc, vault, QUOTE);
switch (LQ.tryLiquidate(st, mg, acc, noReserved, alice, vault, 1, pxCrash)) {
  case (#liquidated(_)) { Debug.print("  ✓ liquidatable user → #liquidated") };
  case (#insolvent(_)) { Debug.print("  ✓ liquidatable user → #insolvent (acceptable: collateral short)") };
  case (_) { Runtime.trap("FAIL: liquidatable user not acted on") };
};
truth("liquidate: debt reduced", BE.loanOf(st, alice, QUOTE) < debtBefore);
truth("liquidate: collateral seized from user", Accounts.getBalance(acc, alice, QUOTE) < aliceBefore);
truth("liquidate: collateral + penalty to vault", Accounts.getBalance(acc, vault, QUOTE) > vaultBefore);
let hAfter = BE.getHealth(st, mg, acc, noReserved, alice, pxCrash);
truth("liquidate: health strictly improved", hAfter.healthRatio > hBefore.healthRatio);
truth("liquidate: restored out of liquidatable range", not hAfter.isLiquidatable);

// ── #insolvent: liquidatable, owes debt, but NO seizable collateral → zero-recovery
//    event (so the insurance fund closes it instead of leaving a perpetual zombie) ──
let (ist, img, iacc) = liquidatableAlice();
// strip ALL of alice's balances: she still owes 40k ICPUSD but holds nothing to seize.
Accounts.setBalance(iacc, alice, "BTC", 0);
Accounts.setBalance(iacc, alice, QUOTE, 0);
let hIns = BE.getHealth(ist, img, iacc, noReserved, alice, px);
truth("insolvent setup: liquidatable", hIns.isLiquidatable);
truth("insolvent setup: still owes debt", hIns.debtUsd > 0);
let debtBeforeIns = BE.loanOf(ist, alice, QUOTE);
switch (LQ.tryLiquidate(ist, img, iacc, noReserved, alice, vault, 1, px)) {
  case (#insolvent(ev)) {
    eqN("insolvent: zero debt repaid", ev.debtRepaid, 0);
    eqN("insolvent: zero collateral seized", ev.collateralSeized, 0);
    truth("insolvent: names the owed token", ev.debtToken == QUOTE);
    Debug.print("  ✓ no-collateral liquidatable user → #insolvent (zero recovery)");
  };
  case (#liquidated(_)) { Runtime.trap("FAIL: seized collateral from a user who has none") };
  case (#healthy) { Runtime.trap("FAIL: reported healthy despite open debt + zero collateral") };
};
// insolvent repays nothing, so the debt is never REDUCED (it may tick up by the
// 1-base-unit interest accrued between the borrow and the liquidation instant).
truth("insolvent: debt not repaid (left standing for the insurance fund)", BE.loanOf(ist, alice, QUOTE) >= debtBeforeIns);

// ── Internal netting: long (holds BTC, owes ICPUSD) ↔ short (holds ICPUSD, owes BTC) ──
let nst = BE.emptyState(); let nmg = ME.emptyState(); let nacc = Accounts.emptyState();
Accounts.setBalance(nacc, vault, QUOTE, 100_000_000_000_000);
Accounts.setBalance(nacc, vault, "BTC", 100_000_000); // 1 BTC lendable (cap 0.5)
// seller (alice): 1 BTC, borrows 30k ICPUSD
switch (ME.open(nmg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(nacc, alice, "BTC", 100_000_000);
switch (BE.borrow(nst, nmg, nacc, noReserved, vault, alice, QUOTE, 3_000_000_000_000, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("seller borrow: " # e) } };
// buyer (bob): 50k ICPUSD, borrows 0.2 BTC
switch (ME.open(nmg, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(nacc, bob, QUOTE, 5_000_000_000_000);
switch (BE.borrow(nst, nmg, nacc, noReserved, vault, bob, "BTC", 20_000_000, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("buyer borrow: " # e) } };

// net 0.2 BTC @ mid 100000 = 20000 cash. Settle at now=0 (same instant as the
// borrows) so no interest accrues — isolates the netting arithmetic.
let settled = LQ.settleNettedPair(nst, nacc, alice, bob, "BTC", 20_000_000, 10_000_000_000_000, vault, 0);
eqN("netting: USD settled = 20000", settled.cash, 2_000_000_000_000);
eqN("netting: base qty settled = 0.2", settled.qty, 20_000_000);
eqN("netting: seller BTC 1.0 → 0.8", Accounts.getBalance(nacc, alice, "BTC"), 80_000_000);
eqN("netting: seller ICPUSD debt 30k → 10k", BE.loanOf(nst, alice, QUOTE), 1_000_000_000_000);
eqN("netting: buyer ICPUSD 50k → 30k", Accounts.getBalance(nacc, bob, QUOTE), 3_000_000_000_000);
eqN("netting: buyer BTC debt 0.2 → 0", BE.loanOf(nst, bob, "BTC"), 0);
eqN("netting: vault absorbed 0.2 BTC", Accounts.getBalance(nacc, vault, "BTC"), 100_000_000); // 1.0 − 0.2 lent + 0.2 netted

Debug.print("── Liquidator.test PASSED ──");
