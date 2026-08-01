// Unit tests for src/backend/lib/VaultMath.mo in integer base units (10^8). Pins
// the ERC-4626 donation-inflation guard on the mint ratio and the over-weight
// deposit-fee curve.

import VM "../src/backend/lib/VaultMath";
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

Debug.print("── VaultMath.test ──");

// ── mintAmount ──
// First deposit of 1000 → 1000 LP (valuePerLP = 1.0).
eqN("mint: first deposit = its value", VM.mintAmount(100_000_000_000, 0, 0), 100_000_000_000);
// Equal-value follow-on (supply 1000, vault 1000, deposit 1000) → ~1000 LP.
eqN("mint: fair follow-on deposit", VM.mintAmount(100_000_000_000, 100_000_000_000, 100_000_000_000), 100_000_000_000);

// ── ERC-4626 donation-inflation guard ──
// Attacker dust supply (0.001 LP), DONATES to inflate vault to 1000, victim
// deposits 1000. Unguarded: value×supply/vaultValue = 1000×0.001/1000 = 0.001 LP.
// Guarded: ~1.0 LP (≈1000× more) — attack neutralised.
let naive : Nat = 100_000;                                   // 0.001 LP (the unguarded mint)
let guarded = VM.mintAmount(100_000_000_000, 100_000, 100_000_000_000); // dust supply 0.001
eqN("mint: guard yields ~1.0 LP", guarded, 100_000_000);
truth("mint: guard mints >> the naive (drained) amount", guarded > naive * 100);

// ── feeMultiplier (weights at 10^8: 0.125 = 12_500_000) ──
eqN("fee: at target = 1.0",     VM.feeMultiplier(12_500_000, 12_500_000), 100_000_000);
eqN("fee: under-weight = 1.0",  VM.feeMultiplier(5_000_000, 12_500_000), 100_000_000);
eqN("fee: zero target = 1.0",   VM.feeMultiplier(50_000_000, 0), 100_000_000);
// 2× target → gap 1.0 → MAX fee → multiplier 0.90
eqN("fee: 2× target → max fee", VM.feeMultiplier(25_000_000, 12_500_000), 90_000_000);
// 1.2× target → gap 0.2 → fee 0.10×0.04 = 0.004 → multiplier 0.996
eqN("fee: mild over-weight",    VM.feeMultiplier(15_000_000, 12_500_000), 99_600_000);
// 4× target → gap² clamped to 1 → fee stays MAX → multiplier 0.90
eqN("fee: capped at max beyond 2×", VM.feeMultiplier(50_000_000, 12_500_000), 90_000_000);

Debug.print("── VaultMath.test PASSED ──");
