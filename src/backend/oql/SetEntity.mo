/// Contextual-dot constructors for `Set.Set<T>` row sources.

import Set    "mo:core/Set";
import Entity "Entity";

module {
  public func toEntity<T>(
    self       : Set.Set<T>,
    name       : Text,
    typeName   : Text,
    primaryKey : Text,
    _toRow     : (implicit : T -> Entity.Row),
  ) : Entity.Builder<T> =
    Entity.new<T>(name, func () = self.values(), typeName, primaryKey, _toRow);

  public func toEntityManual<T>(
    self       : Set.Set<T>,
    name       : Text,
    typeName   : Text,
    primaryKey : Text,
  ) : Entity.Builder<T> =
    Entity.manual<T>(name, func () = self.values(), typeName, primaryKey);
};
