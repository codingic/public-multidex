/// Implicit instance: `Nat -> Value`. Found by structural derivation
/// when a record field has type `Nat`.

import Types "Types";

module {
  public func _toRow(self : Nat) : Types.Value = #nat self;
};
