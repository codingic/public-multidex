// SafeMath.mo — small saturating-arithmetic helpers for the integer ledger.
//
// Motoko's `Nat` subtraction TRAPS on underflow (it never wraps), so the
// codebase guards every defensive subtraction with `if (a > b) { a - b }
// else { 0 }`. That idiom is correct but the compiler can't see the guard, so
// it emits a conservative `M0155 — operator may trap` warning at every site.
//
// `subOrZero` is that idiom, named once. It computes the difference in `Int`
// (which never traps) and clamps to zero, so it is genuinely trap-free AND does
// not itself trigger M0155 — call sites read `SafeMath.subOrZero(a, b)` instead
// of an inline guard, which states the "clamp to zero" intent explicitly.
//
// Use it ONLY where clamping a negative result to 0 is the INTENDED semantics
// (e.g. `available = max(0, balance - reserved)`). Do NOT use it to silence a
// subtraction whose non-negativity is a real INVARIANT — there, the trap is a
// feature (it surfaces a violated invariant instead of masking it with a 0).
import Int "mo:core/Int";

module {
  // max(0, a - b). Never traps; never warns.
  public func subOrZero(a : Nat, b : Nat) : Nat {
    let d = (a : Int) - b;
    if (d > 0) { Int.abs(d) } else { 0 };
  };
};
