/// Implicit instance: `Nat32 -> Value`. `Value` has no `#nat32`, so the
/// instance widens through `Nat`.

import Nat32 "mo:core/Nat32";
import Types "Types";

module {
  public func _toRow(self : Nat32) : Types.Value = #nat (Nat32.toNat(self));
};
