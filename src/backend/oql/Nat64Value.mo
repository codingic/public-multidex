/// Implicit instance: `Nat64 -> Value`. `Value` has no `#nat64`, so the
/// instance widens through `Nat`.

import Nat64 "mo:core/Nat64";
import Types "Types";

module {
  public func _toRow(self : Nat64) : Types.Value = #nat (Nat64.toNat(self));
};
