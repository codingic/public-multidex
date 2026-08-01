// Unit tests for src/backend/lib/MarginEngine.mo — cross-margin collateral
// valuation in integer base units (10^8). Pins LTV haircuts, reserved-funds
// inclusion, unknown-price safety, the bid cap, and the open/close guards.

import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Fixed "../src/backend/lib/Fixed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Array "mo:core/Array";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
let alice = Principal.fromText("aaaaa-aa");
let BTC_PX : Nat = 10_000_000_000_000; // $100000 at 10^8

func px(t : Types.TokenId) : ?Nat {
  switch (t) { case ("BTC") { ?BTC_PX }; case ("ETH") { ?400_000_000_000 }; case (_) { null } };
};
func noReserved(_ : Principal, _ : Types.TokenId) : Nat { 0 };

Debug.print("── MarginEngine.test ──");

// priceOf
eqN("priceOf: quote = 1.0", ME.priceOf(Types.QUOTE_TOKEN, px), Fixed.SCALE);
eqN("priceOf: BTC via lookup", ME.priceOf("BTC", px), BTC_PX);
eqN("priceOf: unknown = 0", ME.priceOf("DOGE", px), 0);

// computeBidCap = cash × 3.0 ($100 → $300)
eqN("bidCap: cash × factor", ME.computeBidCap(10_000_000_000), 30_000_000_000);
eqN("bidCap: zero", ME.computeBidCap(0), 0);

// collateral valuation
let st = ME.emptyState();
let acc = Accounts.emptyState();
truth("valuations: empty without account", Array.size(ME.valuations(st, acc, noReserved, alice, px)) == 0);
eqN("collateral: zero without account", ME.weightedCollateralUsd(st, acc, noReserved, alice, px), 0);

switch (ME.open(st, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("open failed: " # e) } };
Accounts.setBalance(acc, alice, "BTC", 100_000_000);              // 1 BTC
Accounts.setBalance(acc, alice, Types.QUOTE_TOKEN, 100_000_000_000); // 1000 ICPUSD
// BTC: 1 × 100000 × 0.90 = 90000 ; ICPUSD: 1000 × 1 × 1.0 = 1000 ; total 91000.
eqN("collateral: BTC@0.90 + cash@1.0", ME.weightedCollateralUsd(st, acc, noReserved, alice, px), 9_100_000_000_000);

func reservedBtc(_ : Principal, t : Types.TokenId) : Nat { if (t == "BTC") { 50_000_000 } else { 0 } }; // +0.5 BTC
// BTC gross 1.5 → 135000 ; + 1000 = 136000.
eqN("collateral: counts reserved funds", ME.weightedCollateralUsd(st, acc, reservedBtc, alice, px), 13_600_000_000_000);

Accounts.setBalance(acc, alice, "SOL", 1_000_000_000); // 10 SOL, price unknown → 0 contribution
eqN("collateral: unknown price → 0 contrib", ME.weightedCollateralUsd(st, acc, noReserved, alice, px), 9_100_000_000_000);

// open/close guards
switch (ME.open(st, alice, 1)) { case (#err(_)) { Debug.print("  ✓ open: double-open rejected") }; case (#ok(_)) { Runtime.trap("FAIL: double open allowed") } };
switch (ME.close(st, alice, 5_000_000_000)) { case (#err(_)) { Debug.print("  ✓ close: blocked with debt") }; case (#ok) { Runtime.trap("FAIL: closed with debt") } }; // $50 debt
switch (ME.close(st, alice, 0)) { case (#ok) { Debug.print("  ✓ close: ok at zero debt") }; case (#err(e)) { Runtime.trap("FAIL: close zero-debt: " # e) } };
truth("close: account removed", not ME.hasAccount(st, alice));
switch (ME.close(st, alice, 0)) { case (#err(_)) { Debug.print("  ✓ close: no-account rejected") }; case (#ok) { Runtime.trap("FAIL: closed nonexistent account") } };

Debug.print("── MarginEngine.test PASSED ──");
