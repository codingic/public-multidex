/// Implicit instance: `Principal -> Value`. `Value` has no `#principal`,
/// so the instance renders through `Text` via the canonical textual form.

import Principal "mo:core/Principal";
import Types     "Types";

module {
  public func _toRow(self : Principal) : Types.Value = #text (Principal.toText(self));
};
