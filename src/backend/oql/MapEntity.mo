/// Contextual-dot constructors for `Map.Map<K, V>` row sources.
/// Lets users write `customers.toEntity(...)` (auto-derive) or
/// `customers.toEntityManual(...)` (manual escape hatch) instead of
/// piping `func () = customers.values()` into `Entity.new`/`manual`.

import Map    "mo:core/Map";
import Entity "Entity";

module {
  public func toEntity<K, V>(
    self       : Map.Map<K, V>,
    name       : Text,
    typeName   : Text,
    primaryKey : Text,
    _toRow     : (implicit : V -> Entity.Row),
  ) : Entity.Builder<V> =
    Entity.new<V>(name, func () = self.values(), typeName, primaryKey, _toRow);

  public func toEntityManual<K, V>(
    self       : Map.Map<K, V>,
    name       : Text,
    typeName   : Text,
    primaryKey : Text,
  ) : Entity.Builder<V> =
    Entity.manual<V>(name, func () = self.values(), typeName, primaryKey);
};
