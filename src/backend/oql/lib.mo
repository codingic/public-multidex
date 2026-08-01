/// Object Query Layer — top-level surface.
///
/// Typical usage in an actor:
///
///   import OQL    "mo:oql";
///   import Expose "mo:oql/Expose";
///
///   actor {
///     // ... domain types and storage ...
///     include Expose({
///       entities = [
///         // each entity declares its own authorization level; default
///         // is #controllerOnly when none is set.
///         notes.toEntity("note", "Note", "id").ownedBy("owner").scopedPerUser().build(),
///         tags.toEntity("tag", "Tag", "id").public_().build(),
///       ];
///     });
///   };

import _Auth      "Auth";
import _Entity    "Entity";
import _Executor  "Executor";
import _Predicate "Predicate";
import _Query     "Query";
import _Registry  "Registry";
import _Schema    "Schema";
import _Types     "Types";
import _NatValue       "NatValue";
import _IntValue       "IntValue";
import _FloatValue     "FloatValue";
import _TextValue      "TextValue";
import _BoolValue      "BoolValue";
import _Nat8Value      "Nat8Value";
import _Nat16Value     "Nat16Value";
import _Nat32Value     "Nat32Value";
import _Nat64Value     "Nat64Value";
import _Int8Value      "Int8Value";
import _Int16Value     "Int16Value";
import _Int32Value     "Int32Value";
import _Int64Value     "Int64Value";
import _PrincipalValue "PrincipalValue";
import _BlobValue      "BlobValue";
import _RecordValue    "RecordValue";
import _MapEntity      "MapEntity";
import _ArrayEntity    "ArrayEntity";
import _ListEntity     "ListEntity";
import _SetEntity      "SetEntity";
import _VarArrayEntity "VarArrayEntity";
import _SecondaryIndex "SecondaryIndex";
import _IndexedMap     "IndexedMap";
import _Backfill       "Backfill";

module {

  public let Auth      = _Auth;
  public let Types     = _Types;
  public let Predicate = _Predicate;
  public let Query     = _Query;
  public let Schema    = _Schema;
  public let Entity    = _Entity;
  public let Registry  = _Registry;
  public let Executor  = _Executor;

  // Implicit instances for structural `_toRow` derivation. Re-exporting
  // lets users find them via `OQL.<Type>Value` without per-primitive
  // imports — the compiler walks module fields when resolving implicits.
  public let NatValue    = _NatValue;
  public let IntValue    = _IntValue;
  public let FloatValue  = _FloatValue;
  public let TextValue   = _TextValue;
  public let BoolValue   = _BoolValue;
  public let Nat8Value   = _Nat8Value;
  public let Nat16Value  = _Nat16Value;
  public let Nat32Value  = _Nat32Value;
  public let Nat64Value  = _Nat64Value;
  public let Int8Value   = _Int8Value;
  public let Int16Value  = _Int16Value;
  public let Int32Value  = _Int32Value;
  public let Int64Value  = _Int64Value;
  public let PrincipalValue = _PrincipalValue;
  public let BlobValue      = _BlobValue;
  public let RecordValue    = _RecordValue;
  public let MapEntity      = _MapEntity;
  public let ArrayEntity    = _ArrayEntity;
  public let ListEntity     = _ListEntity;
  public let SetEntity      = _SetEntity;
  public let VarArrayEntity = _VarArrayEntity;
  public let SecondaryIndex = _SecondaryIndex;
  public let IndexedMap     = _IndexedMap;
  public let Backfill       = _Backfill;

  public type Value     = _Types.Value;
  public type Path      = _Types.Path;
  public type FieldRole = _Types.FieldRole;
  public type Predicate = _Predicate.Predicate;
  public type Row       = _Predicate.Row;
  public type Query     = _Query.Query;
  public type Decl      = _Entity.Decl;
  public type Result    = _Executor.Result;
  public type Access    = _Auth.Access;
  /// Per-entity authorization level — see Auth / Entity.auth.
  public type TableAuth = _Auth.TableAuth;
  /// App-defined ownership predicate for `.ownedByWith` — see Entity.
  public type OwnerCheck = _Entity.OwnerCheck;
  /// Access kind for a declared secondary index (`#ordered` / `#hash`).
  public type IndexKind = _SecondaryIndex.Kind;

};
