/// Predicate AST + evaluator. Ten relational/logical variants plus four
/// text-search variants; remaining convenience predicates (`#between`,
/// `#isNull`, ...) compose from these.

import Bool  "mo:core/Bool";
import Float "mo:core/Float";
import Int   "mo:core/Int";
import Iter  "mo:core/Iter";
import Nat   "mo:core/Nat";
import Order "mo:core/Order";
import Text  "mo:core/Text";
import Types "Types";

module {

  type Value = Types.Value;
  type Path  = Types.Path;

  public type Predicate = {
    #eq  : (Path, Value);
    #ne  : (Path, Value);
    #lt  : (Path, Value);
    #le  : (Path, Value);
    #gt  : (Path, Value);
    #ge  : (Path, Value);
    #in_ : (Path, [Value]);
    // Text-search relations: true only when both the row value and the
    // operand are `#text`. `#icontains` is case-insensitive (Unicode
    // lowercasing on both sides).
    #contains   : (Path, Value);
    #icontains  : (Path, Value);
    #startsWith : (Path, Value);
    #endsWith   : (Path, Value);
    #and_ : [Predicate];
    #or_  : [Predicate];
    #not_ : Predicate;
  };

  /// A row, viewed for predicate evaluation: it knows how to resolve a path
  /// to a value (or to `null` if the path is absent / hidden).
  ///
  /// Flat-layout fast path for base rows. `slot` resolves a top-level column
  /// name to an index into `values` ONCE (the resolver is shared across every
  /// row of the entity, so no per-row allocation), and `values` is this row's
  /// flat cells — so the executor can resolve a query's columns once and then
  /// index `values` directly per row instead of a name lookup per access.
  /// `slot` is `null` for rows without a flat layout (seed-less / aggregated),
  /// where callers fall back to `get` (and `values` is unused, `[]`).
  public type Row = {
    get    : Path -> ?Value;
    slot   : ?(Text -> ?Nat);
    values : [Value];
  };

  /// Missing fields fail every relation **except `#ne`** — strict
  /// three-valued logic is a later change.
  public func eval(p : Predicate, row : Row) : Bool {
    switch p {
      case (#eq  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #equal) };
      case (#ne  (path, v)) { test(row.get(path), true,  func a = compare(a, v) != #equal) };
      case (#lt  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #less) };
      case (#le  (path, v)) { test(row.get(path), false, func a = compare(a, v) != #greater) };
      case (#gt  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #greater) };
      case (#ge  (path, v)) { test(row.get(path), false, func a = compare(a, v) != #less) };
      case (#in_ (path, vs)) {
        test(row.get(path), false, func a = vs.values().any(func v = compare(a, v) == #equal))
      };
      case (#contains   (path, v)) { textTest(row.get(path), v, func (h, n) = h.contains(#text n)) };
      case (#icontains  (path, v)) { textTest(row.get(path), v, func (h, n) = h.toLower().contains(#text(n.toLower()))) };
      case (#startsWith (path, v)) { textTest(row.get(path), v, func (h, n) = h.startsWith(#text n)) };
      case (#endsWith   (path, v)) { textTest(row.get(path), v, func (h, n) = h.endsWith(#text n)) };
      case (#and_ ps) { ps.values().all(func q = eval(q, row)) };
      case (#or_  ps) { ps.values().any(func q = eval(q, row)) };
      case (#not_ q)  { not eval(q, row) };
    }
  };

  /// True when `actual` is present and `ok` accepts it; `onNull` is the
  /// answer when the field is missing. Centralises the null policy so
  /// strict 3VL is a single-flag change at every call site.
  func test(actual : ?Value, onNull : Bool, ok : Value -> Bool) : Bool =
    switch actual { case null { onNull }; case (?a) { ok(a) } };

  /// Text-only relation: true only when both the row value (haystack) and
  /// the operand (needle) are `#text` and `rel` accepts them. Missing or
  /// non-text fields are false, consistent with the null policy above.
  func textTest(actual : ?Value, operand : Value, rel : (Text, Text) -> Bool) : Bool =
    switch (actual, operand) {
      case (?#text h, #text n) { rel(h, n) };
      case _ { false };
    };

  /// A genuine total order on `Value` — antisymmetric and transitive over
  /// every pair, which `orderBy`/`min`/`max` rely on (an inconsistent
  /// comparator silently corrupts sorts).
  ///
  /// `Nat`/`Int`/`Float` bridge each other: numeric values compare across
  /// these three regardless of which wire form they arrived in, so
  /// `gt(price, 10)` matches a row whose `price` is the Float 12.5.
  ///
  /// Cross-*kind* pairs (`#nat` vs `#text`, or anything vs `#null_`) order
  /// by a fixed kind rank — `null < bool < number < text` — so the answer
  /// is deterministic and self-consistent. (Meaningful queries still
  /// compare like with like; this just guarantees a stable sort when a
  /// column mixes kinds, e.g. a left-joined edge path yielding `null`.)
  ///
  /// Numeric pairs go through `Nat.compare`/`Int.compare`/`Float.compare`
  /// (mo:core names those parameters `x`/`y`, not `self`, so contextual dot
  /// is unavailable). `Float.compare` is itself already a total order across
  /// the float edge cases — NaN sorts greatest and equals only itself,
  /// `-0.0` equals `+0.0` — so no NaN special-casing is needed here. (Both
  /// properties are pinned by the test suite.)
  ///
  /// The `Float`↔`Int`/`Nat` bridge is EXACT (`cmpFloatInt`), not
  /// `Float.fromInt`: past 2^53 that conversion is lossy and would make one
  /// float `#equal` to two distinct integer keys, breaking transitivity — and
  /// with it any ordered structure keyed on `compare`, so an index probe would
  /// under-fetch. So `#eq(#float 2^53)` matches the integer `2^53` only, never
  /// also `2^53 + 1`. Below 2^53 the two bridges agree exactly.
  public func compare(a : Value, b : Value) : Order.Order =
    switch (a, b) {
      case (#null_,  #null_ ) { #equal };
      case (#bool x, #bool y) { x.compare(y) };
      case (#nat   x, #nat   y) { Nat.compare(x, y) };
      case (#int   x, #int   y) { Int.compare(x, y) };
      case (#nat   x, #int   y) { Int.compare(x, y) };
      case (#int   x, #nat   y) { Int.compare(x, y) };
      case (#float x, #float y) { Float.compare(x, y) };
      case (#float x, #nat   y) { cmpFloatInt(x, y) };
      case (#nat   x, #float y) { flipOrder(cmpFloatInt(y, x)) };
      case (#float x, #int   y) { cmpFloatInt(x, y) };
      case (#int   x, #float y) { flipOrder(cmpFloatInt(y, x)) };
      case (#text x, #text y) { x.compare(y) };
      // Different kinds: order by kind rank. (Same-kind pairs — including
      // every numeric combination — are all handled above, so this only
      // ever sees distinct ranks and is therefore strictly ±.)
      case _ { Nat.compare(rank(a), rank(b)) };
    };

  /// Compare a `Float` against an integer EXACTLY, so the numeric bridge stays a
  /// valid total order past 2^53. `Float.fromInt` is lossy there — `fromInt(2^53)
  /// == fromInt(2^53 + 1)` — which would make one float `#equal` to two distinct
  /// integer keys, breaking transitivity and with it every ordered `Map`/`Set`
  /// keyed on `compare` (a secondary-index point probe would land on one bucket
  /// and silently drop the other). An integral float compares as an integer; a
  /// non-integral float falls strictly between its integer neighbours. Non-finite
  /// floats (NaN/±inf) can't collide with an integer, so they keep the plain
  /// `Float.compare` bridge (already total over those).
  func cmpFloatInt(f : Float, i : Int) : Order.Order {
    if (Float.isNaN(f - f)) { return Float.compare(f, Float.fromInt(i)) }; // NaN or ±inf
    let fl = Float.floor(f);
    if (f == fl) { Int.compare(Float.toInt(f), i) }        // integral float → integer compare
    else if (i <= Float.toInt(fl)) { #greater }            // f ∈ (floor, floor+1): f > i
    else { #less };                                        // i ≥ ceil: f < i
  };

  func flipOrder(o : Order.Order) : Order.Order =
    switch o { case (#less) { #greater }; case (#equal) { #equal }; case (#greater) { #less } };

  /// Fixed kind ordering for cross-kind comparisons. Numbers share a rank
  /// so the bridge cases above stay authoritative for numeric pairs.
  func rank(v : Value) : Nat = switch v {
    case (#null_) { 0 };
    case (#bool _) { 1 };
    case (#nat _ or #int _ or #float _) { 2 };
    case (#text _) { 3 };
  };

};
