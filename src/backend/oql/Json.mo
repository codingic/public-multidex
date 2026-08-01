/// JSON query parser. Translates a JSON-encoded `Query` into the typed
/// `Query.Query` AST. Wire format (all keys lowercase, omit anything you
/// don't need):
///
/// ```json
/// {
///   "start":   "customer",
///   "where":   { "and": [
///                 { "eq": { "field": "country", "value": "DE" } },
///                 { "gt": { "field": "age",     "value": 18   } }
///               ] },
///   "orderBy": [ { "field": "name", "dir": "asc" } ],
///   "offset":  0,
///   "limit":   10,
///   "select":  [ "id", "name", "country" ]
/// }
/// ```
///
/// Predicate operators: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `in`,
/// `contains`, `icontains`, `startsWith`, `endsWith`,
/// `and` (array of predicates), `or` (array of predicates), `not` (single
/// predicate). Comparison ops take `{ "field": <Text>, "value": <scalar> }`.
/// `in` takes `{ "field": <Text>, "value": [<scalar>, ...] }` — the row
/// matches when its value at `field` equals any value in the array. Empty
/// array is legal and matches nothing. Text-search ops (`contains`,
/// `icontains`, `startsWith`, `endsWith`) take `{ "field": <Text>,
/// "value": <Text> }` — a non-string value is a parse error; `icontains`
/// is case-insensitive. `dir` is `"asc"` or `"desc"` (default `"asc"`).
/// Field paths may be dotted (`"department.name"`): each dot before the
/// final segment crosses a declared edge to the target entity.

import Json      "mo:json";
import Iter      "mo:core/Iter";
import List      "mo:core/List";
import Nat       "mo:core/Nat";
import Text      "mo:core/Text";
import Predicate "Predicate";
import Query     "Query";
import Types     "Types";

module {

  public type ParseResult = Query.ParseResult;

  type Value = Types.Value;
  type Path  = Types.Path;
  type Pred  = Predicate.Predicate;

  type Outcome<T> = { #ok : T; #err : Text };

  public func parseQuery(text : Text) : ParseResult {
    switch (Json.parse(text)) {
      case (#err e) { #err("OQL.Json: " # Json.errToText(e)) };
      case (#ok j)  { fromJson(j) };
    };
  };

  // ── Top-level query ───────────────────────────────────────────────────

  func fromJson(j : Json.Json) : ParseResult {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("query must be a JSON object") };
    };

    let start = switch (field(entries, "start")) {
      case (?#string s) { s };
      case _ { return #err("query.start: missing or not a string") };
    };

    let where_ : ?Pred = switch (field(entries, "where")) {
      case null     { null };
      case (?node)  {
        switch (parsePredicate(node)) {
          case (#err e) { return #err("query.where: " # e) };
          case (#ok p)  { ?p };
        };
      };
    };

    let orderBy : [Query.OrderBy] = switch (field(entries, "orderBy")) {
      case null         { [] };
      case (?#array xs) {
        switch (mapOk<Json.Json, Query.OrderBy>(xs, parseOrderBy)) {
          case (#err e) { return #err("query.orderBy: " # e) };
          case (#ok o)  { o };
        };
      };
      case _ { return #err("query.orderBy: must be an array") };
    };

    let offset = switch (parseNat(field(entries, "offset"))) {
      case (#err e) { return #err("query.offset: " # e) };
      case (#ok n)  { n };
    };
    let limit = switch (parseNat(field(entries, "limit"))) {
      case (#err e) { return #err("query.limit: " # e) };
      case (#ok n)  { n };
    };

    let select : ?[Path] = switch (field(entries, "select")) {
      case null         { null };
      case (?#array xs) {
        switch (mapOk<Json.Json, Path>(xs, parsePathItem)) {
          case (#err e) { return #err("query.select: " # e) };
          case (#ok ps) { ?ps };
        };
      };
      case _ { return #err("query.select: must be an array of strings") };
    };

    let groupBy : [Path] = switch (field(entries, "groupBy")) {
      case null         { [] };
      case (?#array xs) {
        switch (mapOk<Json.Json, Path>(xs, parsePathItem)) {
          case (#err e) { return #err("query.groupBy: " # e) };
          case (#ok ps) { ps };
        };
      };
      case _ { return #err("query.groupBy: must be an array of strings") };
    };

    let aggregate : [Query.Agg] = switch (field(entries, "aggregate")) {
      case null         { [] };
      case (?#array xs) {
        switch (mapOk<Json.Json, Query.Agg>(xs, parseAgg)) {
          case (#err e) { return #err("query.aggregate: " # e) };
          case (#ok a)  { a };
        };
      };
      case _ { return #err("query.aggregate: must be an array of objects") };
    };

    #ok({ start; where_; groupBy; aggregate; orderBy; offset; limit; select });
  };

  /// `{ "fn": "count"|"sum"|"avg"|"min"|"max", "field": <Text>?, "as": <Text>? }`.
  /// `field` is required for every fn except `count`.
  func parseAgg(j : Json.Json) : Outcome<Query.Agg> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("aggregate entry must be a JSON object") };
    };
    let fn : Query.AggFn = switch (field(entries, "fn")) {
      case (?#string "count") { #count };
      case (?#string "sum")   { #sum };
      case (?#string "avg")   { #avg };
      case (?#string "min")   { #min };
      case (?#string "max")   { #max };
      case (?#string other)   { return #err("unknown aggregate fn '" # other # "'") };
      case _ { return #err("aggregate.fn: missing or not a string") };
    };
    let aggField : ?Path = switch (field(entries, "field")) {
      case null             { null };
      case (?#string s)     {
        switch (parsePath(s)) { case (#ok p) { ?p }; case (#err e) { return #err(e) } }
      };
      case _ { return #err("aggregate.field: must be a string") };
    };
    let as_ : ?Text = switch (field(entries, "as")) {
      case null             { null };
      case (?#string s)     {
        // A dot in an output column name would make it unreachable: any
        // later reference parses as a path and trips edge validation.
        if (s.contains(#char '.')) return #err("aggregate.as: must not contain '.'");
        ?s
      };
      case _ { return #err("aggregate.as: must be a string") };
    };
    switch (fn, aggField) {
      case (#count, _) {};
      case (_, null)   { return #err("aggregate.field is required for this fn") };
      case (_, ?_)     {};
    };
    #ok({ fn; field = aggField; as_ });
  };

  // ── Predicates ────────────────────────────────────────────────────────

  func parsePredicate(j : Json.Json) : Outcome<Pred> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("predicate must be a JSON object") };
    };
    if (entries.size() != 1) {
      return #err("predicate must have exactly one key (got " # entries.size().toText() # ")");
    };
    let (op, payload) = entries[0];
    switch op {
      case "eq" { parseCmp(payload, func (p, v) = #eq(p, v)) };
      case "ne" { parseCmp(payload, func (p, v) = #ne(p, v)) };
      case "lt" { parseCmp(payload, func (p, v) = #lt(p, v)) };
      case "le" { parseCmp(payload, func (p, v) = #le(p, v)) };
      case "gt" { parseCmp(payload, func (p, v) = #gt(p, v)) };
      case "ge" { parseCmp(payload, func (p, v) = #ge(p, v)) };
      case "in" { parseIn(payload) };
      case "contains"   { parseTextCmp(payload, func (p, v) = #contains(p, v)) };
      case "icontains"  { parseTextCmp(payload, func (p, v) = #icontains(p, v)) };
      case "startsWith" { parseTextCmp(payload, func (p, v) = #startsWith(p, v)) };
      case "endsWith"   { parseTextCmp(payload, func (p, v) = #endsWith(p, v)) };
      case "and" { parseLogicArray(payload, func ps = #and_(ps)) };
      case "or"  { parseLogicArray(payload, func ps = #or_(ps)) };
      case "not" {
        switch (parsePredicate(payload)) {
          case (#err e) { #err("not: " # e) };
          case (#ok p)  { #ok(#not_(p)) };
        };
      };
      case _ { #err("unknown predicate op '" # op # "'") };
    };
  };

  func parseCmp(j : Json.Json, build : (Path, Value) -> Pred) : Outcome<Pred> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("comparison must be { \"field\": ..., \"value\": ... }") };
    };
    let path = switch (pathField(entries, "missing 'field'")) {
      case (#ok p) { p }; case (#err e) { return #err(e) };
    };
    let value = switch (field(entries, "value")) {
      case null     { return #err("missing 'value'") };
      case (?node)  {
        switch (parseValue(node)) {
          case (#err e) { return #err(e) };
          case (#ok v)  { v };
        };
      };
    };
    #ok(build(path, value));
  };

  /// Like `parseCmp` but the value must be a JSON string — the text-search
  /// operators are text-only, and a non-string operand is a query bug worth
  /// surfacing at parse time rather than silently matching nothing.
  func parseTextCmp(j : Json.Json, build : (Path, Value) -> Pred) : Outcome<Pred> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("comparison must be { \"field\": ..., \"value\": ... }") };
    };
    let path = switch (pathField(entries, "missing 'field'")) {
      case (#ok p) { p }; case (#err e) { return #err(e) };
    };
    switch (field(entries, "value")) {
      case (?#string s) { #ok(build(path, #text(s))) };
      case _ { #err("'value' must be a string for text-search operators") };
    };
  };

  /// `{ "field": <Text>, "value": [<scalar>, ...] }`. The array may be
  /// empty (matches nothing) but every element must be a scalar
  /// (`#null_` / `#bool` / `#nat` / `#int` / `#float` / `#text`).
  func parseIn(j : Json.Json) : Outcome<Pred> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("in: must be { \"field\": ..., \"value\": [...] }") };
    };
    let path = switch (pathField(entries, "in: missing 'field'")) {
      case (#ok p) { p }; case (#err e) { return #err(e) };
    };
    let items = switch (field(entries, "value")) {
      case (?#array xs) { xs };
      case _ { return #err("in: 'value' must be an array of scalars") };
    };
    switch (mapOk<Json.Json, Value>(items, parseValue)) {
      case (#err e) { #err("in.value: " # e) };
      case (#ok vs) { #ok(#in_(path, vs)) };
    };
  };

  func parseLogicArray(j : Json.Json, build : [Pred] -> Pred) : Outcome<Pred> {
    let xs = switch j {
      case (#array a) { a };
      case _ { return #err("must be an array of predicates") };
    };
    switch (mapOk<Json.Json, Pred>(xs, parsePredicate)) {
      case (#err e) { #err(e) };
      case (#ok ps) { #ok(build(ps)) };
    };
  };

  // ── Scalars + orderBy + paths ─────────────────────────────────────────

  func parseValue(j : Json.Json) : Outcome<Value> =
    switch j {
      case (#null_)              { #ok(#null_) };
      case (#bool b)             { #ok(#bool(b)) };
      case (#string s)           { #ok(#text(s)) };
      case (#number(#int n))     { #ok(if (n >= 0) #nat(Nat.fromInt(n)) else #int(n)) };
      case (#number(#float f))   { #ok(#float(f)) };
      case (#object_ _)          { #err("nested objects are not allowed as scalar values") };
      case (#array _)            { #err("arrays are not allowed as scalar values") };
    };

  func parseOrderBy(j : Json.Json) : Outcome<Query.OrderBy> {
    let entries = switch j {
      case (#object_ es) { es };
      case _ { return #err("orderBy entry must be a JSON object") };
    };
    let f = switch (pathField(entries, "orderBy.field: missing or not a string")) {
      case (#ok p) { p }; case (#err e) { return #err(e) };
    };
    let dir : Query.Dir = switch (field(entries, "dir")) {
      case null              { #asc };
      case (?#string "asc")  { #asc };
      case (?#string "desc") { #desc };
      case _ { return #err("orderBy.dir: must be \"asc\" or \"desc\"") };
    };
    #ok({ field = f; dir });
  };

  /// The `"field"` entry of a comparison-shaped object, parsed as a path.
  func pathField(entries : [(Text, Json.Json)], missing : Text) : Outcome<Path> =
    switch (field(entries, "field")) {
      case (?#string s) { parsePath(s) };
      case _ { #err(missing) };
    };

  /// `"department.name"` -> `["department", "name"]`. Empty segments
  /// (leading/trailing/double dots) are malformed.
  func parsePath(s : Text) : Outcome<Path> {
    let segs = s.split(#char '.').toArray();
    for (seg in segs.values()) {
      if (seg == "") return #err("invalid path '" # s # "'");
    };
    #ok(segs)
  };

  func parsePathItem(j : Json.Json) : Outcome<Path> =
    switch j {
      case (#string s) { parsePath(s) };
      case _           { #err("path entry must be a string") };
    };

  /// Optional non-negative integer: missing → `#ok null`, otherwise must be
  /// `#number(#int n)` with `n >= 0`.
  func parseNat(node : ?Json.Json) : Outcome<?Nat> =
    switch node {
      case null               { #ok null };
      case (?#number(#int n)) {
        if (n < 0) #err("must be a non-negative integer") else #ok(?Nat.fromInt(n))
      };
      case _ { #err("must be a non-negative integer") };
    };

  // ── Object lookup + result-aware map ──────────────────────────────────

  func field(entries : [(Text, Json.Json)], key : Text) : ?Json.Json {
    for ((k, v) in entries.values()) { if (k == key) return ?v };
    null
  };

  /// `Array.map` but short-circuits on the first `#err`.
  func mapOk<A, B>(xs : [A], f : A -> Outcome<B>) : Outcome<[B]> {
    let acc = List.empty<B>();
    for (x in xs.values()) {
      switch (f(x)) {
        case (#err e) { return #err(e) };
        case (#ok b)  { acc.add(b) };
      };
    };
    #ok(acc.toArray());
  };

};
