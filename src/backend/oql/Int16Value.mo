/// Implicit instance: `Int16 -> Value`. `Value` has no `#int16`, so the
/// instance widens through `Int`.

import Int16 "mo:core/Int16";
import Types "Types";

module {
  public func _toRow(self : Int16) : Types.Value = #int (Int16.toInt(self));
};
