/// In-memory entity registry. The mixin builds one from the `entities`
/// array at actor init (and again on every upgrade — entity decls capture
/// closures over actor state and can't be persisted).

import Array "mo:core/Array";
import Iter   "mo:core/Iter";
import List   "mo:core/List";
import Map    "mo:core/Map";
import Text   "mo:core/Text";
import Auth   "Auth";
import Entity "Entity";
import Schema "Schema";

module {

  public type Registry = { byName : Map.Map<Text, Entity.Decl> };

  /// Per-entity read decision — see Executor.Access. Used here to project a
  /// caller-specific schema.
  public type Access = Entity.Decl -> Auth.Access;

  public func build(decls : [Entity.Decl]) : Registry {
    let byName = Map.empty<Text, Entity.Decl>();
    for (d in decls.values()) { byName.add(Text.compare, d.name, d) };
    { byName }
  };

  public func lookup(r : Registry, name : Text) : ?Entity.Decl =
    r.byName.get(Text.compare, name);

  /// Project the registry into the schema document `schema()` returns,
  /// filtered to what `access` permits this caller: entities the caller is
  /// denied are omitted entirely, and within a visible entity any `#edge`
  /// field whose target is denied or absent is pruned (so the schema never
  /// advertises a traversal that would always resolve to null).
  /// `Entity.Decl` carries an extra `rows` closure that `EntityDecl` lacks;
  /// the map drops it.
  public func schema(r : Registry, access : Access) : Schema.Document {
    func visible(d : Entity.Decl) : Bool = access(d) != #deny;

    func keepField(f : Schema.FieldDecl) : Bool =
      switch (f.role) {
        case (#edge { to }) {
          switch (r.byName.get(Text.compare, to)) { case (?t) { visible(t) }; case null { false } };
        };
        case _ { true };
      };

    let out = List.empty<Schema.EntityDecl>();
    for (d in r.byName.values()) {
      if (visible(d)) {
        out.add({
          name = d.name; typeName = d.typeName; primaryKey = d.primaryKey;
          fields = d.fields.filter(keepField);
        });
      };
    };
    { entities = out.toArray() }
  };

};
