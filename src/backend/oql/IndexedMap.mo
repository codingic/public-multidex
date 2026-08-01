/// An observable `Map<K, V>` that maintains OQL secondary indexes on write.
///
/// The staleness-free index, built on owned writes: the wrapper mediates every
/// mutation, so `put`/`delete` keep the declared indexes in step with the data
/// (an update reads the old value first, then removes the stale index entry and
/// adds the new). The index is always fresh — no snapshot, no version stamp, no
/// rebuild — at `O(log n)` per changed column per write.
///
/// PERSISTENCE: `IndexedMap` is **pure data** — a `Map` plus per-column `Map`s
/// of `Set`s, and nothing else. It stores NO function values, so it is `stable`
/// and survives a canister upgrade directly:
///
/// ```motoko
/// var users = IndexedMap.new<Nat, User>([("email", #hash), ("age", #ordered)]);   // persists
/// ```
///
/// The comparator (`compare`) and the row lineariser (`_toRow`) are **implicit**
/// parameters of each operation — never stored, which is what keeps the value
/// persistable — and BOTH derive automatically at the call: `compare` from `K`
/// (as `mo:core`'s `Map.add` resolves it), and `_toRow` via the compiler's
/// `__record` combiner over `V` (the param is named `_toRow` so the derivation
/// fires, same as `Entity.new`). So `m.put(k, v)` takes no explicit args; pass a
/// lineariser only for a custom mapping the derivation can't produce (e.g. a
/// field rendered as `#null_`). Internally each op forwards the resolved
/// functions explicitly, so nothing re-resolves an implicit across modules.
///
/// The index keys come from the same `_toRow` an OQL entity uses, so index keys
/// and query columns agree by construction. Multiple independent single-column
/// indexes are supported, and `newWith` adds composite (multi-column, ordered)
/// indexes — an equality prefix plus a range/orderBy on the next column is
/// served as one contiguous seek of the composite key space. `addIndex`/
/// `addComposite` declare an index over EXISTING rows; it starts serving only
/// once its resumable chunked backfill completes (see `Backfill`).
///
/// SAFETY: correctness rests on writes going THROUGH the wrapper — never mutate
/// the underlying map directly, or the index desyncs.

import Iter    "mo:core/Iter";
import Map     "mo:core/Map";
import Option  "mo:core/Option";
import Order   "mo:core/Order";
import Backfill "Backfill";
import Entity  "Entity";
import Predicate "Predicate";
import SecondaryIndex "SecondaryIndex";
import Types   "Types";

module {

  type Value = Types.Value;
  type Row   = [(Text, Value)];   // Entity.Row

  public type Kind = SecondaryIndex.Kind;

  /// A `Map<K, V>` plus its maintained indexes — pure data (no functions), so a
  /// persistent `var` of this type persists across upgrades. `K` is the row
  /// reference the postings hold.
  public type IndexedMap<K, V> = {
    inner : Map.Map<K, V>;
    ix    : SecondaryIndex.Index<K>;
  };

  /// A fresh empty indexed map over the given columns. Takes no functions, so
  /// its result is a valid persistent-`var` initialiser.
  public func new<K, V>(indexes : [(Text, Kind)]) : IndexedMap<K, V> = newWith(indexes, []);

  /// Like `new`, with composite (multi-column, `#ordered`) indexes alongside
  /// the single-column ones. Each composite's column list is in KEY order —
  /// `["dept", "salary"]` serves an equality prefix on `dept` plus a
  /// range/orderBy on `salary`, not the other way around.
  public func newWith<K, V>(indexes : [(Text, Kind)], composites : [([Text], Kind)]) : IndexedMap<K, V> = {
    inner = Map.empty<K, V>();
    ix    = SecondaryIndex.emptyWith<K>(indexes, composites);
  };

  // ── adding an index later (over existing rows) ───────────────────────────

  /// Declare a NEW single-column index on live data. The decl registers now —
  /// every subsequent write maintains it — but the column stays UNINDEXED to
  /// the planner and the `candidates*` accessors until the returned backfill
  /// walk completes (`Backfill.step` until done; see `Backfill` for the
  /// chunk-from-a-timer pattern). Never a partial serve: mid-backfill, a query
  /// on `col` scans, exactly as before the call (issue #45/#49). Traps if
  /// `col` is already declared.
  public func addIndex<K, V>(self : IndexedMap<K, V>, col : Text, kind : Kind) : Backfill.State<K> {
    SecondaryIndex.addDecl<K>(self.ix, #col col, kind);
    Backfill.start<K>(#col col)
  };

  /// `addIndex` for a composite declaration — the column list in KEY order,
  /// as `newWith`. The same readiness gate: the composite serves only once
  /// the returned walk completes.
  public func addComposite<K, V>(self : IndexedMap<K, V>, cols : [Text], kind : Kind) : Backfill.State<K> {
    SecondaryIndex.addDecl<K>(self.ix, #cols cols, kind);
    Backfill.start<K>(#cols cols)
  };

  // ── reads ────────────────────────────────────────────────────────────────
  // The receiver is named `self` so every op is callable as `m.get(...)` etc.
  // via contextual-dot (the `mo:core` method convention) as well as
  // `IndexedMap.get(m, ...)`.
  public func get<K, V>(self : IndexedMap<K, V>, k : K, compare : (implicit : (K, K) -> Order.Order)) : ?V =
    self.inner.get(compare, k);
  public func size<K, V>(self : IndexedMap<K, V>) : Nat = self.inner.size();
  public func values<K, V>(self : IndexedMap<K, V>) : Iter.Iter<V> = self.inner.values();
  public func entries<K, V>(self : IndexedMap<K, V>) : Iter.Iter<(K, V)> = self.inner.entries();

  // ── writes (index-maintaining) ────────────────────────────────────────────

  /// Insert or replace `k`. Reads the old value first, so an update removes the
  /// stale index entry before adding the new one. `compare`/`_toRow` are
  /// resolved from `K`/`V` (implicit, both derive) and forwarded explicitly.
  public func put<K, V>(
    self    : IndexedMap<K, V>,
    k       : K,
    v       : V,
    compare : (implicit : (K, K) -> Order.Order),
    _toRow  : (implicit : V -> Row),
  ) {
    let old = self.inner.get(compare, k);
    self.inner.add(compare, k, v);
    SecondaryIndex.onChange<K>(self.ix, compare, k, Option.map<V, Row>(old, _toRow), ?(_toRow(v)));
  };

  /// Remove `k`, dropping its postings from every index.
  public func delete<K, V>(
    self    : IndexedMap<K, V>,
    k       : K,
    compare : (implicit : (K, K) -> Order.Order),
    _toRow  : (implicit : V -> Row),
  ) {
    let old = self.inner.get(compare, k);
    ignore self.inner.delete(compare, k);
    SecondaryIndex.onChange<K>(self.ix, compare, k, Option.map<V, Row>(old, _toRow), null);
  };

  // ── index-served candidates (SUPERSET; caller applies the residual filter) ─

  func materialize<K, V>(self : IndexedMap<K, V>, compare : (K, K) -> Order.Order, refs : Iter.Iter<K>) : Iter.Iter<(K, V)> =
    refs.filterMap(func (k : K) : ?(K, V) =
      Option.map<V, (K, V)>(self.inner.get(compare, k), func (v : V) : (K, V) = (k, v)));

  public func candidatesEq<K, V>(self : IndexedMap<K, V>, col : Text, key : Value, compare : (implicit : (K, K) -> Order.Order)) : Iter.Iter<(K, V)> =
    materialize(self, compare, SecondaryIndex.point(self.ix, col, key));

  public func candidatesIn<K, V>(self : IndexedMap<K, V>, col : Text, keys : [Value], compare : (implicit : (K, K) -> Order.Order)) : Iter.Iter<(K, V)> =
    materialize(self, compare, SecondaryIndex.points(self.ix, col, keys));

  public func candidatesRange<K, V>(self : IndexedMap<K, V>, col : Text, lo : ?Value, hi : ?Value, dir : { #asc; #desc }, compare : (implicit : (K, K) -> Order.Order)) : Iter.Iter<(K, V)> =
    materialize(self, compare, SecondaryIndex.range(self.ix, col, lo, hi, dir));

  public func candidatesComposite<K, V>(self : IndexedMap<K, V>, cols : [Text], prefixEqs : [Value], lo : ?Value, hi : ?Value, dir : { #asc; #desc }, compare : (implicit : (K, K) -> Order.Order)) : Iter.Iter<(K, V)> =
    materialize(self, compare, SecondaryIndex.compositeRange(self.ix, cols, prefixEqs, lo, hi, dir));

  // ── OQL entity ──────────────────────────────────────────────────────────

  /// An OQL entity over the current contents. The entity carries a `served`
  /// capability, so the executor's planner answers sargable unrestricted
  /// queries (`#eq` on any indexed column; single-field `orderBy` on an
  /// `#ordered` one) from the live index instead of scanning; anything else
  /// falls back to the full scan. `compare`/`_toRow` are implicit (derive from
  /// `K`/`V`) — the same resolvers the writes use, so index keys and query
  /// columns agree by construction.
  public func entity<K, V>(
    self       : IndexedMap<K, V>,
    name       : Text,
    typeName   : Text,
    primaryKey : Text,
    compare    : (implicit : (K, K) -> Order.Order),
    _toRow     : (implicit : V -> Row),
  ) : Entity.Builder<V> {
    let base = Entity.new<V>(name, func () = self.inner.values(), typeName, primaryKey, _toRow);
    Entity.withServed<V>(base, func (toPredRow : V -> Predicate.Row) : Entity.Served {
      // Resolve each ref (K) to its row through the live map, then linearise
      // with the entity's own `toPredRow` — a ref dropped since the index was
      // probed simply materialises to nothing.
      func rows(refs : Iter.Iter<K>) : Iter.Iter<Predicate.Row> =
        refs.filterMap(func (k : K) : ?Predicate.Row =
          Option.map<V, Predicate.Row>(self.inner.get(compare, k), toPredRow));
      {
        kindOf = func (col : Text) : ?SecondaryIndex.Kind = SecondaryIndex.kindOf(self.ix, col);
        point  = func (col : Text, key : Value) : Iter.Iter<Predicate.Row> =
          rows(SecondaryIndex.point(self.ix, col, key));
        points = func (col : Text, keys : [Value]) : Iter.Iter<Predicate.Row> =
          rows(SecondaryIndex.points(self.ix, col, keys));
        range  = func (col : Text, lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Predicate.Row> =
          rows(SecondaryIndex.range(self.ix, col, lo, hi, dir));
        // Always wired (not gated on decls2 being non-empty at build): a
        // composite can be declared LATER (`addComposite`), and `decls` is
        // re-read per query so it starts serving the moment its backfill
        // completes — and never before (a pending decl is not listed).
        composites = ?{
          decls = func () : [[Text]] = SecondaryIndex.readyComposites(self.ix);
          range = func (cols : [Text], prefixEqs : [Value], lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Predicate.Row> =
            rows(SecondaryIndex.compositeRange(self.ix, cols, prefixEqs, lo, hi, dir));
        };
        // Aggregate stats straight off the postings — `total` is the live row
        // count; the rest delegate to `SecondaryIndex`, which gates readiness.
        stats = ?{
          total      = func () : Nat = self.inner.size();
          count      = func (col : Text, v : Value) : ?Nat = SecondaryIndex.count(self.ix, col, v);
          min        = func (col : Text) : ?Value = SecondaryIndex.minOf(self.ix, col);
          max        = func (col : Text) : ?Value = SecondaryIndex.maxOf(self.ix, col);
          groupCount = func (col : Text) : ?Iter.Iter<(Value, Nat)> = SecondaryIndex.groupCount(self.ix, col);
        };
      }
    });
  };

};
