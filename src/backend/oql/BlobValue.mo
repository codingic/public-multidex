/// Implicit instance: `Blob -> Value`. `Value` has no `#blob` arm, so the
/// instance renders through `Text` — mirroring PrincipalValue.
///
/// ExternalBlob (object-storage) references are UTF-8 text ("!caf!sha256:…"),
/// so decoding surfaces the readable reference. Without this instance a
/// record carrying a `Blob` field cannot auto-derive via `Entity.new`,
/// forcing `Entity.manual` (whose default `toRow` is empty) — which is how
/// blob-bearing entities silently collapsed to `record {}` / empty rows.
///
/// ponytail: UTF-8-or-size heuristic. Arbitrary binary that is not valid
/// UTF-8 renders as a size placeholder; add base64/hex if a real binary
/// blob field ever needs its raw bytes queryable.

import Text  "mo:core/Text";
import Nat   "mo:core/Nat";
import Types "Types";

module {
  public func _toRow(self : Blob) : Types.Value =
    switch (Text.decodeUtf8(self)) {
      case (?t) #text t;
      case null #text ("<blob:" # Nat.toText(self.size()) # " bytes>");
    };
};
