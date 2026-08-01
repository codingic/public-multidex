/// Implicit instance: `Bool -> Value`.

import Types "Types";

module {
  public func _toRow(self : Bool) : Types.Value = #bool self;
};
