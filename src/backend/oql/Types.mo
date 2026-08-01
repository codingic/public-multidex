/// Shared vocabulary: scalar `Value`, dotted `Path`, and `FieldRole`.

import Text "mo:core/Text";

module {

  public type Value = {
    #null_;
    #bool  : Bool;
    #nat   : Nat;
    #int   : Int;
    #float : Float;
    #text  : Text;
  };

  /// Multi-segment paths traverse declared edges: in `["dept", "name"]`
  /// every segment before the last crosses an `#edge` field to its target
  /// entity. Nested-record access could reuse the shape later,
  /// disambiguated by the head segment's field role.
  public type Path = [Text];

  public type FieldRole = {
    #payload;
    /// Foreign-key scalar pointing at another entity. The FK value ships
    /// inline; dotted query paths traverse it to the target server-side.
    #edge : { to : Text };
    /// Holds the row's owner principal (rendered as `#text`). When the
    /// caller resolves to a scoped subject, the entity yields only rows
    /// whose owner column equals that subject. A plain queryable column
    /// otherwise — surfaced in `schema()` so clients know the rows are
    /// auto-filtered and must not add their own owner predicate.
    #owner;
    /// Filtered out of the schema, default projections, and explicit `select`.
    #hidden;
  };

  public func pathToText(p : Path) : Text = p.values().join(".");

};
