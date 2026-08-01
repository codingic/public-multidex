/// Implicit instance: `Float -> Value`.

import Types "Types";

module {
  public func _toRow(self : Float) : Types.Value = #float self;
};
