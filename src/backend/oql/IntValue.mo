/// Implicit instance: `Int -> Value`.

import Types "Types";

module {
  public func _toRow(self : Int) : Types.Value = #int self;
};
