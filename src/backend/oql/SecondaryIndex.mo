/// Incrementally-maintained secondary indexes over an entity's rows.
///
/// The store is `column -> (Value -> Set<Ref>)`: one ordered `Map` per declared
/// column, keyed on the column value via `Predicate.compare` (the same total
/// order `orderBy`/joins use), its values the row references carrying that key.
/// One structure answers both access patterns — a point probe (`#eq`/`#in_`)
/// and an ordered range scan (`#lt`..`#ge`, single-field `orderBy`).
///
/// Maintenance is INCREMENTAL, not a rebuild: the owning collection wrapper
/// (e.g. `IndexedMap`) calls `onChange(ref, oldRow, newRow)` on every mutation,
/// having read the old value first — so insert (`oldRow = null`), update (both
/// present), and delete (`newRow = null`) each keep the index exactly in step
/// with the data. The index is therefore never stale and never rebuilt; the
/// cost is `O(log n)` per changed column per write, not `O(n)` per read.
///
/// An index only ever supplies a SUPERSET of the true matches in key order —
/// range bounds are inclusive, `#null_` is indexed like any key — so the caller
/// re-applies the full predicate per row (the residual filter). An index can
/// make a query faster, never wrong.
///
/// Postings are a `Set<Ref>` (not a list) so update/delete can remove a single
/// ref in `O(log k)`; iterating the set yields refs in `Ref` order, which is
/// what lets the executor's stable sort resolve orderBy ties exactly as a scan
/// (whose rows arrive in that same key order) does.
///
/// An index can also be declared LATER, over existing rows (`addDecl`): the
/// store is maintained from that moment, but the decl stays PENDING —
/// unservable, `kindOf` null — until a resumable backfill walk (`Backfill`)
/// has indexed every pre-existing row and `markReady` flips it.
///
/// COMPOSITE indexes generalise the same store to multi-column keys: `byCols`
/// is `columns -> ([Value] -> Set<Ref>)`, one ordered `Map` per declared
/// column LIST, keyed on the row's key VECTOR under `compareSeq` (element-wise
/// `Predicate.compare`, lexicographic). One structure answers an equality
/// prefix (`dept = "eng"`), a prefix plus a range on the next column
/// (`dept = "eng" and salary >= 50`), and a prefix-ordered scan (`orderBy
/// salary` under a pinned `dept`) — all as one contiguous seek. Maintenance,
/// null handling, and superset semantics are exactly the single-column story.

import Array     "mo:core/Array";
import Iter      "mo:core/Iter";
import List      "mo:core/List";
import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Order     "mo:core/Order";
import Runtime   "mo:core/Runtime";
import Set       "mo:core/Set";
import Text      "mo:core/Text";
import Predicate "Predicate";
import Types     "Types";

module {

  type Value = Types.Value;
  type Row   = [(Text, Value)];   // the assoc-array row (Entity.Row)

  /// `#ordered` supports point + range + single-field `orderBy`; `#hash`
  /// supports point (`#eq`/`#in_`) only. It is one `Map` container either way;
  /// the kind only advises which access patterns a planner will attempt. (No
  /// planner in this module — kind is carried for the executor wiring to come.)
  public type Kind = { #ordered; #hash };

  type ColIndex<Ref> = Map.Map<Value, Set.Set<Ref>>;
  type SeqIndex<Ref> = Map.Map<[Value], Set.Set<Ref>>;

  /// The maintained index set for one entity: the declarations and the
  /// per-column stores. PURE DATA — no function values — so it persists under
  /// enhanced orthogonal persistence (mo:core `Map`/`Set` store no comparator;
  /// the `Ref` comparator is passed into `onChange` per call, not stored).
  ///
  /// `decls2`/`byCols` are the composite declarations and their stores: each
  /// decl is an ordered column list (the KEY order — a prefix seeks, a suffix
  /// does not), `#ordered` only in v1. Every key vector in a store has exactly
  /// its decl's column count.
  ///
  /// `pending`/`pending2` hold the decls added over EXISTING data (`addDecl`)
  /// whose backfill walk has not completed. A pending decl is maintained by
  /// `onChange` (so the walk and live writes converge) but is UNINDEXED to
  /// every reader — `kindOf`/`compositeOf` report `null` and the accessors
  /// yield nothing — because a half-built store is not a superset of anything
  /// (the issue #45/#49 silent-under-fetch class). Readiness lives HERE, with
  /// the index data, so it persists with it: an upgrade mid-backfill resumes
  /// safely, still unservable.
  public type Index<Ref> = {
    var decls  : [(Text, Kind)];
    byCol  : Map.Map<Text, ColIndex<Ref>>;
    var decls2 : [([Text], Kind)];
    byCols : Map.Map<[Text], SeqIndex<Ref>>;
    pending  : Set.Set<Text>;
    pending2 : Set.Set<[Text]>;
  };

  public func empty<Ref>(decls : [(Text, Kind)]) : Index<Ref> = emptyWith(decls, []);

  /// Like `empty`, with composite (multi-column, `#ordered`) declarations
  /// alongside the single-column ones. Declarations made at construction are
  /// ready immediately — the collection is empty, so there is nothing to fill.
  public func emptyWith<Ref>(decls : [(Text, Kind)], composites : [([Text], Kind)]) : Index<Ref> {
    let byCol = Map.empty<Text, ColIndex<Ref>>();
    for ((col, _) in decls.values()) { byCol.add(Text.compare, col, Map.empty<Value, Set.Set<Ref>>()) };
    let byCols = Map.empty<[Text], SeqIndex<Ref>>();
    for ((cols, _) in composites.values()) { byCols.add(compareCols, cols, Map.empty<[Value], Set.Set<Ref>>()) };
    { var decls = decls; byCol; var decls2 = composites; byCols;
      pending = Set.empty<Text>(); pending2 = Set.empty<[Text]>() };
  };

  /// One declared index, as a backfill target: a single column or a composite
  /// column list (in KEY order, as declared).
  public type Target = { #col : Text; #cols : [Text] };

  /// Register a NEW declaration over live data. The store is created empty
  /// and the decl marked PENDING: `onChange` maintains it from this moment
  /// (live writes converge with the backfill walk), but `kindOf`/
  /// `compositeOf` — and so the planner and the accessors — treat it as
  /// unindexed until `markReady`. Traps on a duplicate declaration: two
  /// walks racing one store would have no owner for the ready flip.
  public func addDecl<Ref>(ix : Index<Ref>, target : Target, kind : Kind) {
    switch target {
      case (#col col) {
        if (declaredCol(ix, col)) Runtime.trap("OQL: index on '" # col # "' is already declared");
        ix.decls := ix.decls.concat([(col, kind)]);
        ix.byCol.add(Text.compare, col, Map.empty<Value, Set.Set<Ref>>());
        ix.pending.add(Text.compare, col);
      };
      case (#cols cols) {
        if (declaredCols(ix, cols)) Runtime.trap("OQL: composite index on '" # cols.values().join(",") # "' is already declared");
        ix.decls2 := ix.decls2.concat([(cols, kind)]);
        ix.byCols.add(compareCols, cols, Map.empty<[Value], Set.Set<Ref>>());
        ix.pending2.add(compareCols, cols);
      };
    };
  };

  /// Flip `target` from pending to ready — the backfill walk's final act.
  /// Only now do `kindOf`/`compositeOf` expose the decl, so the planner can
  /// route to it: the store is complete, a true superset.
  public func markReady<Ref>(ix : Index<Ref>, target : Target) {
    switch target {
      case (#col col)   { ignore ix.pending.delete(Text.compare, col) };
      case (#cols cols) { ignore ix.pending2.delete(compareCols, cols) };
    };
  };

  func declaredCol<Ref>(ix : Index<Ref>, col : Text) : Bool {
    for ((c, _) in ix.decls.values()) { if (c == col) return true };
    false
  };

  func declaredCols<Ref>(ix : Index<Ref>, cols : [Text]) : Bool {
    for ((cs, _) in ix.decls2.values()) { if (cs == cols) return true };
    false
  };

  /// The declared kind of `col`, or `null` if it is not indexed — the planner's
  /// gate for what an index can serve. A PENDING column (declared, backfill in
  /// flight) is `null` too: its store is partial, so it must gate exactly like
  /// an unindexed one.
  public func kindOf<Ref>(ix : Index<Ref>, col : Text) : ?Kind {
    if (ix.pending.contains(Text.compare, col)) return null;
    for ((c, k) in ix.decls.values()) { if (c == col) return ?k };
    null
  };

  /// The declared kind of the composite `cols` (the exact column list, in
  /// order), or `null` if no such composite is declared — `kindOf`'s gate,
  /// for composites, with the same pending rule. An undeclared or pending
  /// composite must never route to the index: its store is not a superset
  /// of anything.
  public func compositeOf<Ref>(ix : Index<Ref>, cols : [Text]) : ?Kind {
    if (ix.pending2.contains(compareCols, cols)) return null;
    for ((cs, k) in ix.decls2.values()) { if (cs == cols) return ?k };
    null
  };

  /// The READY composite column lists — what a `Served` capability may
  /// advertise to the planner. A pending composite is absent, so a plan can
  /// never seek a half-built store.
  public func readyComposites<Ref>(ix : Index<Ref>) : [[Text]] {
    let acc = List.empty<[Text]>();
    for ((cols, _) in ix.decls2.values()) {
      if (not ix.pending2.contains(compareCols, cols)) acc.add(cols);
    };
    acc.toArray()
  };

  func compareCols(a : [Text], b : [Text]) : Order.Order = a.compare(b, Text.compare);

  /// Lexicographic order on composite key vectors: element-wise
  /// `Predicate.compare` (so numeric kinds bridge exactly, as on every
  /// single-column key), a shorter vector ordering BEFORE its extensions.
  /// Deliberately NOT a text encoding of the vector — that would sort 10
  /// before 9 and sever the `#nat`/`#int`/`#float` bridge.
  public func compareSeq(a : [Value], b : [Value]) : Order.Order {
    let n = Nat.min(a.size(), b.size());
    var i = 0;
    while (i < n) {
      switch (Predicate.compare(a[i], b[i])) { case (#equal) {}; case o { return o } };
      i += 1;
    };
    Nat.compare(a.size(), b.size());
  };

  // Probe order for DESCENDING seeks: element-wise like `compareSeq`, but a
  // shorter vector orders AFTER its extensions (pad-with-+infinity). Stored
  // keys of one composite store all share the decl's column count, so the
  // flipped length rule only ever positions a shorter PROBE — it agrees with
  // `compareSeq` on every stored-key pair, which is what keeps
  // `reverseEntriesFrom` consistent with the store's build order.
  func compareSeqFromAbove(a : [Value], b : [Value]) : Order.Order {
    let n = Nat.min(a.size(), b.size());
    var i = 0;
    while (i < n) {
      switch (Predicate.compare(a[i], b[i])) { case (#equal) {}; case o { return o } };
      i += 1;
    };
    Nat.compare(b.size(), a.size());
  };

  // A row's value for `col`: the cell if present, else `#null_` (missing fields
  // index under null, so a query for null still finds them).
  func keyOf(row : Row, col : Text) : Value {
    for ((k, v) in row.values()) { if (k == col) return v };
    #null_
  };

  // The key a (possibly absent) row contributes for `col`: `null` when there is
  // no row (an insert has no old row; a delete has no new row).
  func cellOf(row : ?Row, col : Text) : ?Value =
    switch row { case (?r) ?keyOf(r, col); case null null };

  // The key VECTOR a (possibly absent) row contributes for a composite's
  // `cols` — each cell via `keyOf`, so missing fields index under `#null_`
  // exactly as in a single-column key.
  func seqOf(row : ?Row, cols : [Text]) : ?[Value] =
    switch row { case (?r) ?cols.map(func (c : Text) : Value = keyOf(r, c)); case null null };

  func sameKey(a : ?Value, b : ?Value) : Bool =
    switch (a, b) {
      case (null, null) { true };
      case (?x, ?y) { Predicate.compare(x, y) == #equal };
      case _ { false };
    };

  func sameSeq(a : ?[Value], b : ?[Value]) : Bool =
    switch (a, b) {
      case (null, null) { true };
      case (?x, ?y) { compareSeq(x, y) == #equal };
      case _ { false };
    };

  func addRef<K, Ref>(ci : Map.Map<K, Set.Set<Ref>>, keyCmp : (K, K) -> Order.Order, refCmp : (Ref, Ref) -> Order.Order, key : K, ref : Ref) {
    switch (ci.get(keyCmp, key)) {
      case (?s) { s.add(refCmp, ref) };
      case null { let s = Set.empty<Ref>(); s.add(refCmp, ref); ci.add(keyCmp, key, s) };
    };
  };

  func removeRef<K, Ref>(ci : Map.Map<K, Set.Set<Ref>>, keyCmp : (K, K) -> Order.Order, refCmp : (Ref, Ref) -> Order.Order, key : K, ref : Ref) {
    switch (ci.get(keyCmp, key)) {
      case (?s) { ignore s.delete(refCmp, ref); if (s.size() == 0) ignore ci.delete(keyCmp, key) };
      case null {};
    };
  };

  /// Reflect one mutation of `ref` in every declared index. `refCmp` orders the
  /// posting sets (the caller passes the already-resolved `Ref` comparator — no
  /// function is stored in the index). `oldRow`/`newRow` are the row's
  /// linearised cells before/after (`null` for the absent side of an insert or
  /// delete). Per column — and per composite, whose key is the column-value
  /// vector — if the key is unchanged the index is skipped; otherwise the old
  /// posting is removed and the new one added.
  public func onChange<Ref>(ix : Index<Ref>, refCmp : (Ref, Ref) -> Order.Order, ref : Ref, oldRow : ?Row, newRow : ?Row) {
    for ((col, _) in ix.decls.values()) {
      let oldKey = cellOf(oldRow, col);
      let newKey = cellOf(newRow, col);
      if (not sameKey(oldKey, newKey)) {
        let ci = switch (ix.byCol.get(Text.compare, col)) { case (?c) c; case null { let c = Map.empty<Value, Set.Set<Ref>>(); ix.byCol.add(Text.compare, col, c); c } };
        switch oldKey { case (?k) removeRef(ci, Predicate.compare, refCmp, k, ref); case null {} };
        switch newKey { case (?k) addRef(ci, Predicate.compare, refCmp, k, ref); case null {} };
      };
    };
    for ((cols, _) in ix.decls2.values()) {
      let oldKey = seqOf(oldRow, cols);
      let newKey = seqOf(newRow, cols);
      if (not sameSeq(oldKey, newKey)) {
        let ci = switch (ix.byCols.get(compareCols, cols)) { case (?c) c; case null { let c = Map.empty<[Value], Set.Set<Ref>>(); ix.byCols.add(compareCols, cols, c); c } };
        switch oldKey { case (?k) removeRef(ci, compareSeq, refCmp, k, ref); case null {} };
        switch newKey { case (?k) addRef(ci, compareSeq, refCmp, k, ref); case null {} };
      };
    };
  };

  /// Backfill: reflect ONE existing row in the single decl `target` names —
  /// the resumable walk's per-row write (`Backfill.step`). Idempotent: the
  /// posting `Set` dedups, so a row a live `onChange` already indexed lands
  /// once when the walk reaches it. An undeclared target is a no-op.
  public func indexOne<Ref>(ix : Index<Ref>, refCmp : (Ref, Ref) -> Order.Order, ref : Ref, row : Row, target : Target) {
    switch target {
      case (#col col) {
        switch (ix.byCol.get(Text.compare, col)) {
          case (?ci) { addRef(ci, Predicate.compare, refCmp, keyOf(row, col), ref) };
          case null {};
        };
      };
      case (#cols cols) {
        switch (ix.byCols.get(compareCols, cols)) {
          case (?ci) { addRef(ci, compareSeq, refCmp, cols.map(func (c : Text) : Value = keyOf(row, c)), ref) };
          case null {};
        };
      };
    };
  };

  func emptyIter<Ref>() : Iter.Iter<Ref> = { next = func () : ?Ref = null };

  // The column's store for SERVING, or `null` when `col` is unindexed OR
  // still pending — a pending store is partial, and a partial stream is not
  // a superset, so it must read exactly like an unindexed column. (`onChange`
  // and `indexOne` reach the store directly; only the accessors gate.)
  func colOf<Ref>(ix : Index<Ref>, col : Text) : ?ColIndex<Ref> =
    if (ix.pending.contains(Text.compare, col)) null
    else ix.byCol.get(Text.compare, col);

  /// Refs whose `col` equals `key` (point probe). Superset-safe: the set holds
  /// exactly the rows keyed there; the caller's residual filter still runs.
  public func point<Ref>(ix : Index<Ref>, col : Text, key : Value) : Iter.Iter<Ref> =
    switch (colOf(ix, col)) {
      case null { emptyIter() };
      case (?ci) { switch (ci.get(Predicate.compare, key)) { case (?s) s.values(); case null emptyIter() } };
    };

  /// Union of point probes for `#in_`, keys de-duplicated through
  /// `Predicate.compare` (so `[#nat 50, #int 50]` collapse to one probe and a
  /// row surfaces once). Distinct keys map to disjoint posting sets.
  public func points<Ref>(ix : Index<Ref>, col : Text, keys : [Value]) : Iter.Iter<Ref> =
    switch (colOf(ix, col)) {
      case null { emptyIter() };
      case (?ci) {
        let seen = Set.empty<Value>();
        let uniq = List.empty<Value>();
        for (k in keys.values()) { if (not seen.contains(Predicate.compare, k)) { seen.add(Predicate.compare, k); uniq.add(k) } };
        uniq.values().flatMap(func (k : Value) : Iter.Iter<Ref> =
          switch (ci.get(Predicate.compare, k)) { case (?s) s.values(); case null emptyIter() });
      };
    };

  /// Refs whose `col` lies in `[lo, hi]` (each bound optional, inclusive),
  /// streamed in key order — ascending, or descending per `dir`. Lazy, so a
  /// caller cap can stop it early. Bounds are inclusive by design: a strict
  /// `#lt`/`#gt` still passes its boundary key here and the residual filter
  /// drops it, keeping the stream a clean superset.
  public func range<Ref>(ix : Index<Ref>, col : Text, lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Ref> =
    switch (colOf(ix, col)) {
      case null { emptyIter() };
      case (?ci) {
        let entries : Iter.Iter<(Value, Set.Set<Ref>)> = switch dir {
          case (#asc)  { switch lo { case (?l) ci.entriesFrom(Predicate.compare, l);        case null ci.entries() } };
          case (#desc) { switch hi { case (?h) ci.reverseEntriesFrom(Predicate.compare, h); case null ci.reverseEntries() } };
        };
        let bounded = entries.takeWhile(func ((k, _) : (Value, Set.Set<Ref>)) : Bool =
          switch dir {
            case (#asc)  { switch hi { case (?h) Predicate.compare(k, h) != #greater; case null true } };
            case (#desc) { switch lo { case (?l) Predicate.compare(k, l) != #less;    case null true } };
          });
        bounded.flatMap(func ((_, s) : (Value, Set.Set<Ref>)) : Iter.Iter<Ref> = s.values());
      };
    };

  // ── derived statistics (exact, O(1)–O(#keys), no scan) ─────────────────────
  // All read straight off the postings via `colOf`, so they inherit its
  // readiness gate: a not-declared or pending column reports `null` and the
  // caller falls back to a scan. Never an estimate — these back aggregate
  // ANSWERS, so they must equal a scan of the same predicate.

  /// Number of refs whose `col` equals `v` — the posting size (0 if none). The
  /// exact `count(*) where col = v`. `null` when `col` isn't ready-indexed.
  public func count<Ref>(ix : Index<Ref>, col : Text, v : Value) : ?Nat =
    switch (colOf(ix, col)) {
      case null { null };
      case (?ci) { ?(switch (ci.get(Predicate.compare, v)) { case (?s) { s.size() }; case null { 0 } }) };
    };

  /// The smallest / largest NON-`#null_` value present in `col` — `min`/`max`
  /// ignore nulls, exactly as the scan aggregate does. `null` when the column
  /// holds no non-null value (empty or all-null → the scan returns `#null_`).
  public func minOf<Ref>(ix : Index<Ref>, col : Text) : ?Value =
    switch (colOf(ix, col)) {
      case null { null };
      case (?ci) { firstNonNull(ci.entries()) };
    };
  public func maxOf<Ref>(ix : Index<Ref>, col : Text) : ?Value =
    switch (colOf(ix, col)) {
      case null { null };
      case (?ci) { firstNonNull(ci.reverseEntries()) };
    };
  func firstNonNull<Ref>(it : Iter.Iter<(Value, Set.Set<Ref>)>) : ?Value {
    for ((k, _) in it) { if (k != #null_) return ?k };
    null
  };

  /// Per-value counts — the `groupBy col → count(*)` histogram, one entry per
  /// distinct value (including `#null_`), each with its posting size, in value
  /// order. `null` when `col` isn't ready-indexed.
  public func groupCount<Ref>(ix : Index<Ref>, col : Text) : ?Iter.Iter<(Value, Nat)> =
    switch (colOf(ix, col)) {
      case null { null };
      case (?ci) {
        let out = List.empty<(Value, Nat)>();
        for ((k, s) in ci.entries()) { out.add((k, s.size())) };
        ?out.values()
      };
    };

  // `colOf` for composites — the same pending gate.
  func colsOf<Ref>(ix : Index<Ref>, cols : [Text]) : ?SeqIndex<Ref> =
    if (ix.pending2.contains(compareCols, cols)) null
    else ix.byCols.get(compareCols, cols);

  /// Refs of the composite `cols` whose key vector starts with `prefixEqs`
  /// (element-wise equality) and whose NEXT column — `cols[prefixEqs.size()]`
  /// — lies in `[lo, hi]` (each bound optional, inclusive), streamed in
  /// composite key order, ascending or descending per `dir`. One contiguous
  /// seek: `entriesFrom` the `prefixEqs ++ bound` probe (a shorter probe
  /// orders before its extensions — or, descending, after them — so the seek
  /// lands on the prefix's first/last key), then `takeWhile` the equality
  /// prefix still matches and the next column is within the far bound. Lazy,
  /// so a caller cap can stop it early. Superset semantics as everywhere:
  /// bounds inclusive, the caller's residual filter re-checks every row.
  /// Bounds are ignored when the prefix already pins every column. An
  /// UNDECLARED (or still-pending) composite yields nothing — callers must
  /// gate on `compositeOf`, because an empty stream is not a superset of
  /// anything.
  public func compositeRange<Ref>(ix : Index<Ref>, cols : [Text], prefixEqs : [Value], lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Ref> =
    switch (colsOf(ix, cols)) {
      case null { emptyIter() };
      case (?ci) {
        let k = prefixEqs.size();
        // A full-length prefix leaves no next column to bound.
        let (lo_, hi_) = if (k < cols.size()) (lo, hi) else (null, null);
        let entries : Iter.Iter<([Value], Set.Set<Ref>)> = switch dir {
          case (#asc) {
            let probe = switch lo_ { case (?l) prefixEqs.concat([l]); case null prefixEqs };
            if (probe.size() == 0) ci.entries() else ci.entriesFrom(compareSeq, probe);
          };
          case (#desc) {
            let probe = switch hi_ { case (?h) prefixEqs.concat([h]); case null prefixEqs };
            if (probe.size() == 0) ci.reverseEntries() else ci.reverseEntriesFrom(compareSeqFromAbove, probe);
          };
        };
        let bounded = entries.takeWhile(func ((key, _) : ([Value], Set.Set<Ref>)) : Bool {
          var i = 0;
          while (i < k) {
            if (i >= key.size() or Predicate.compare(key[i], prefixEqs[i]) != #equal) return false;
            i += 1;
          };
          if (k >= key.size()) return true;   // prefix pins every column: nothing left to bound
          switch dir {
            case (#asc)  { switch hi_ { case (?h) Predicate.compare(key[k], h) != #greater; case null true } };
            case (#desc) { switch lo_ { case (?l) Predicate.compare(key[k], l) != #less;    case null true } };
          };
        });
        bounded.flatMap(func ((_, s) : ([Value], Set.Set<Ref>)) : Iter.Iter<Ref> = s.values());
      };
    };

};
