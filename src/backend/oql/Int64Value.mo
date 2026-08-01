/// Implicit instance: `Int64 -> Value`. `Value` has no `#int64`, so the
/// instance widens through `Int`.

import Int64 "mo:core/Int64";
import Types "Types";

module {
  public func _toRow(self : Int64) : Types.Value = #int (Int64.toInt(self));
};
