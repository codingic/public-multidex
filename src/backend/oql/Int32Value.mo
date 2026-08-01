/// Implicit instance: `Int32 -> Value`. `Value` has no `#int32`, so the
/// instance widens through `Int`.

import Int32 "mo:core/Int32";
import Types "Types";

module {
  public func _toRow(self : Int32) : Types.Value = #int (Int32.toInt(self));
};
