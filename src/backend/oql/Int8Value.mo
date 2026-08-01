/// Implicit instance: `Int8 -> Value`. `Value` has no `#int8`, so the
/// instance widens through `Int`.

import Int8  "mo:core/Int8";
import Types "Types";

module {
  public func _toRow(self : Int8) : Types.Value = #int (Int8.toInt(self));
};
