// Unit tests for src/backend/lib/Accounts.mo — the integer balance ledger (base
// units, 10^8 = 1 whole token). The invariant that matters most for a money
// system: subtractBalance REFUSES an overdraft (false, balance untouched) and
// never goes negative — now EXACT integer arithmetic, so even 1 base-unit over
// is refused (no Float tolerance). Plus per-user isolation in getUserBalances.

import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
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
let bob = Principal.fromText("2vxsx-fae"); // anonymous principal — distinct from alice

Debug.print("── Accounts.test ──");
let acc = Accounts.emptyState();

// Absent balance reads as 0.
eqN("getBalance: empty = 0", Accounts.getBalance(acc, alice, "BTC"), 0);

// set / add round-trips (amounts in base units: 250_000_000 = 2.5 BTC).
Accounts.setBalance(acc, alice, "BTC", 250_000_000);
eqN("setBalance round-trip", Accounts.getBalance(acc, alice, "BTC"), 250_000_000);
Accounts.addBalance(acc, alice, "BTC", 150_000_000);
eqN("addBalance accumulates", Accounts.getBalance(acc, alice, "BTC"), 400_000_000);
Accounts.addBalance(acc, alice, "ETH", 300_000_000);
eqN("addBalance from zero (new token)", Accounts.getBalance(acc, alice, "ETH"), 300_000_000);

// subtractBalance: sufficient → true and reduces.
truth("subtract: sufficient → true", Accounts.subtractBalance(acc, alice, "BTC", 100_000_000));
eqN("subtract: balance reduced", Accounts.getBalance(acc, alice, "BTC"), 300_000_000);

// INSUFFICIENT → false AND balance untouched (overdraft guard).
truth("subtract: insufficient → false", not Accounts.subtractBalance(acc, alice, "BTC", 10_000_000_000));
eqN("subtract: balance unchanged on reject", Accounts.getBalance(acc, alice, "BTC"), 300_000_000);

// Exact drain → true and zero.
truth("subtract: exact → true", Accounts.subtractBalance(acc, alice, "BTC", 300_000_000));
eqN("subtract: exact → 0", Accounts.getBalance(acc, alice, "BTC"), 0);

// EXACT: even 1 base-unit over the balance is refused (no tolerance).
Accounts.setBalance(acc, alice, "ICP", 500_000_000);
truth("subtract: 1 unit over → refused", not Accounts.subtractBalance(acc, alice, "ICP", 500_000_001));
eqN("subtract: balance intact after refusal", Accounts.getBalance(acc, alice, "ICP"), 500_000_000);
truth("subtract: exact-to-zero → true", Accounts.subtractBalance(acc, alice, "ICP", 500_000_000));
eqN("subtract: now zero, never negative", Accounts.getBalance(acc, alice, "ICP"), 0);

// getUserBalances: only this user's NON-ZERO tokens; no cross-user leakage.
Accounts.setBalance(acc, alice, "BTC", 100_000_000); // re-fund: alice = BTC 1.0, ETH 3.0, ICP 0
Accounts.setBalance(acc, bob, "BTC", 9_900_000_000);
let aliceBals = Accounts.getUserBalances(acc, alice);
truth("getUserBalances: 2 non-zero (BTC, ETH; ICP=0 excluded)", Array.size(aliceBals) == 2);
var aliceBtc : Nat = 0;
for ((t, b) in aliceBals.vals()) { if (t == "BTC") { aliceBtc := b } };
eqN("getUserBalances: alice BTC = 1.0 (not bob's 99)", aliceBtc, 100_000_000);

// balKey: stable "principal#token" form (the shared reserved-ledger key).
truth("balKey format", Accounts.balKey(alice, "BTC") == Principal.toText(alice) # "#BTC");

Debug.print("── Accounts.test PASSED ──");
