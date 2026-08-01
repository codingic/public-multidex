// VaultMath.mo — pure AMM-vault LP math in integer base units (10^8). The
// ERC-4626-style donation-inflation guard on the mint ratio, and the over-weight
// deposit-fee curve. No state — primitives in, Nat out. Mint rounds DOWN (LP to
// the depositor — protect existing LPs); fee rounds UP (charged to the depositor).

import Nat "mo:core/Nat";
import Fixed "Fixed";

module {
  // Max over-weight deposit fee (0.10 at 10^8).
  public let LP_FEE_MAX : Nat = 10_000_000;
  // Virtual share/asset offset (OpenZeppelin pattern), 1.0 at 10^8.
  public let LP_VIRTUAL_LP    : Nat = 100_000_000;
  public let LP_VIRTUAL_VALUE : Nat = 100_000_000;

  // LP minted for a deposit worth `effectiveValue` (already fee-scaled), given
  // the PRE-deposit supply + vault value. First deposit (supply 0) anchors
  // valuePerLP = 1.0; thereafter the virtual offsets bound donation-inflation.
  // Rounds DOWN — the depositor receives no more than their fair share.
  public func mintAmount(effectiveValue : Nat, lpSupply : Nat, vaultTotalQuoteValue : Nat) : Nat {
    if (lpSupply == 0) {
      effectiveValue
    } else {
      Fixed.mulDiv(effectiveValue, lpSupply + LP_VIRTUAL_LP, vaultTotalQuoteValue + LP_VIRTUAL_VALUE, false)
    };
  };

  // Deposit-fee multiplier ∈ [1 − LP_FEE_MAX, 1.0] (10^8-scaled) for an asset at
  // `curWeight` vs `targetWeight`. At/under-weight → 1.0; over-weight → a
  // quadratically-ramping fee, rounded UP (against the depositor), capped at MAX.
  public func feeMultiplier(curWeight : Nat, targetWeight : Nat) : Nat {
    if (targetWeight == 0 or curWeight <= targetWeight) { return Fixed.SCALE };
    let over : Nat = curWeight - targetWeight;           // > 0
    let gap  = Fixed.div(over, targetWeight, true);       // fractional over-weight
    let gap2 = Fixed.mul(gap, gap, true);
    let capped = Nat.min(Fixed.SCALE, gap2);              // clamp gap² to 1.0
    let fee = Fixed.mul(LP_FEE_MAX, capped, true);
    Fixed.SCALE - fee
  };
};
