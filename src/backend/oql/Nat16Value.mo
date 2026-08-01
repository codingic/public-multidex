/// Implicit instance: `Nat16 -> Value`. `Value` has no `#nat16`, so the
/// instance widens through `Nat`.

import Nat16 "mo:core/Nat16";
import Types "Types";

module {
  public func _toRow(self : Nat16) : Types.Value = #nat (Nat16.toNat(self));
};
