/// Implicit instance: `Nat8 -> Value`. `Value` has no `#nat8`, so the
/// instance widens through `Nat`.

import Nat8  "mo:core/Nat8";
import Types "Types";

module {
  public func _toRow(self : Nat8) : Types.Value = #nat (Nat8.toNat(self));
};
