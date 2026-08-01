/// The query AST. Fixed pipeline (see `Executor.mo`), predicate
/// variants in `Predicate.mo`.
///
/// JSON-agnostic on purpose: `Json.mo` is the single seam where the wire
/// format plugs in; `Expose.mo` wires the two together.

import Predicate "Predicate";
import Types     "Types";

module {

  public type Dir = { #asc; #desc };

  public type OrderBy = {
    field : Types.Path;
    dir   : Dir;
  };

  /// Aggregate function. `#count` ignores `field`; the rest fold over a
  /// numeric field (`#min`/`#max` also work on text).
  public type AggFn = { #count; #sum; #avg; #min; #max };

  public type Agg = {
    fn    : AggFn;
    field : ?Types.Path;   // required for sum/avg/min/max; ignored by count
    as_   : ?Text;         // output column name; defaults to e.g. "sum_amount"
  };

  /// When `groupBy` or `aggregate` is non-empty the executor runs the
  /// aggregation stage (between `where` and `orderBy`): rows are bucketed
  /// by the `groupBy` keys and each bucket collapses to one output row of
  /// the group keys plus the computed aggregate columns. `orderBy` /
  /// `offset` / `limit` / `select` then apply to those grouped rows.
  public type Query = {
    start     : Text;                    // entity name
    where_    : ?Predicate.Predicate;
    groupBy   : [Types.Path];            // [] = no grouping
    aggregate : [Agg];                   // [] = no aggregation
    orderBy   : [OrderBy];
    offset    : ?Nat;
    limit     : ?Nat;
    select    : ?[Types.Path];           // null = all payload fields
  };

  public type ParseResult = { #ok : Query; #err : Text };

};
