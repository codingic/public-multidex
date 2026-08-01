/// Implicit instance: `Text -> Value`.

import Types "Types";

module {
  public func _toRow(self : Text) : Types.Value = #text self;
};
