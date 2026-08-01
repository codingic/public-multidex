/// Structural combiner: turns any record `T` into `[(Text, Value)]` by
/// resolving an `_toRow` instance for each field. The `__record`
/// parameter is the compiler's structural decomposition contract:
/// it arrives as a list of `(fieldName, () -> Value)` thunks.

import Array "mo:core/Array";
import Types "Types";

module {
  type Value = Types.Value;

  public func _toRow(__record : [(Text, () -> Value)]) : [(Text, Value)] =
    __record.map(func ((k, f)) = (k, f()));
};
