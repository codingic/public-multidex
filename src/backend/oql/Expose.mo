/// The `Expose` mixin. `include OQL.Expose({ entities = [...] })` adds two
/// public query functions to the actor:
///
///   schema()            : async Text              — JSON schema document
///   execute(qJson)      : async Result            — typed Candid result
///
/// Authorization is per entity: each `Entity.Decl` declares a `TableAuth`
/// level (default `#controllerOnly`), and at query time
/// `Auth.resolve(level, caller)` yields that entity's read `Access`:
///
///   #deny          — this caller may not read the entity
///   #unrestricted  — read every row of the entity
///   #scoped p      — read only the rows the entity's owner check admits for
///                    principal `p` (see Entity.ownedBy/ownedByWith)
///
/// Both `schema()` and `execute()` honour those decisions: `schema()` hides
/// entities (and edges to them) the caller cannot read, and `execute()`
/// scopes rows per entity — start AND join targets — so a caller never
/// sees, directly or through a join, rows a level denies them.
///
/// `execute` is named so because `query` is a reserved keyword in Motoko.

import Auth      "Auth";
import Entity    "Entity";
import Executor  "Executor";
import Json      "Json";
import Registry  "Registry";
import Runtime   "mo:core/Runtime";
import Schema    "Schema";

mixin (config : {
  entities : [Entity.Decl];
}) {

  /// Re-built on every upgrade — entity decls capture closures over actor
  /// fields, which can't be persisted.
  transient let registry : Registry.Registry = Registry.build(config.entities);

  public shared query ({ caller }) func schema() : async Text {
    let access = func (d : Entity.Decl) : Auth.Access = Auth.resolve(d.auth, caller);
    Schema.toJson(Registry.schema(registry, access));
  };

  public shared query ({ caller }) func execute(qJson : Text) : async Executor.Result {
    let access = func (d : Entity.Decl) : Auth.Access = Auth.resolve(d.auth, caller);
    switch (Json.parseQuery(qJson)) {
      case (#err e) { Runtime.trap("OQL: invalid query — " # e) };
      case (#ok q)  { Executor.runWith(registry, q, access) };
    };
  };

};
