/// Resumable, chunked backfill of a later-declared index over existing rows.
///
/// `IndexedMap.addIndex`/`addComposite` register the declaration and return a
/// `State` — the walk's cursor over the inner map. From that moment the store
/// exists and live writes maintain it (`onChange`), but the decl is PENDING:
/// `kindOf`/`compositeOf` report `null`, the planner falls back to the scan,
/// and the candidate accessors yield nothing — a half-built index is not a
/// superset of anything (the issue #45/#49 silent-under-fetch class). Each
/// `step` indexes a bounded chunk of rows; when the walk completes it flips
/// the decl ready, and only then does the index serve.
///
/// The walk and concurrent writes CONVERGE. Behind the cursor a write lands
/// in an already-walked region, where `onChange` reconciles postings exactly
/// as on a ready index. Ahead of it, `onChange` indexes the new value now and
/// the walk re-indexes the row later — idempotent, the posting `Set` dedups —
/// while a delete simply removes the row before the walk reaches it. The
/// iterator is NEVER held across calls: every `step` re-seeks
/// `entriesFrom(cursor)`, so mutation between steps (the cursor row's own
/// deletion included) cannot invalidate the walk.
///
/// Canister usage — chunk from a timer, so no single message pays for the
/// whole table (`State` is pure data; held in a persistent `var` it survives
/// an upgrade and resumes at its cursor):
///
/// ```motoko
/// var users = IndexedMap.new<Nat, User>([("email", #hash)]);
/// var fill : ?Backfill.State<Nat> = null;
///
/// public func addAgeIndex() : async () {
///   fill := ?users.addIndex("age", #ordered);
///   func chunk() : async () {
///     switch fill {
///       case (?st) { if (Backfill.step(users, st, 10_000)) { fill := null } else { ignore Timer.setTimer<system>(#seconds 0, chunk) } };
///       case null {};
///     };
///   };
///   ignore Timer.setTimer<system>(#seconds 0, chunk);
/// };
/// ```

import Map   "mo:core/Map";
import Order "mo:core/Order";
import SecondaryIndex "SecondaryIndex";
import Types "Types";

module {

  type Row = [(Text, Types.Value)];   // Entity.Row

  /// The collection shape the walk reads: structurally `IndexedMap.IndexedMap`
  /// (spelled here rather than imported — `IndexedMap.addIndex` returns our
  /// `State` and imports may not cycle; structural typing makes the two
  /// interchangeable).
  public type Indexed<K, V> = {
    inner : Map.Map<K, V>;
    ix    : SecondaryIndex.Index<K>;
  };

  /// One in-flight backfill: the decl it fills, the last row already indexed
  /// (`null` before the first step), and completion. Pure data — persists.
  public type State<K> = {
    target : SecondaryIndex.Target;
    var cursor : ?K;
    var done   : Bool;
  };

  /// A fresh walk over `target`, which must already be registered pending
  /// (`SecondaryIndex.addDecl` — `IndexedMap.addIndex`/`addComposite` do
  /// both and hand the state back).
  public func start<K>(target : SecondaryIndex.Target) : State<K> =
    { target; var cursor = null; var done = false };

  /// Index up to `budgetRows` rows from the cursor — within THIS call only —
  /// advancing the cursor per row, and report whether the walk is complete
  /// (flipping the decl ready the moment it is). Call repeatedly until it
  /// returns `true`; a `budgetRows` of 0 makes no progress. Idempotent per
  /// row, so a row also caught by a live write lands once. `compare`/`_toRow`
  /// resolve implicitly from `K`/`V` exactly as on the `IndexedMap` ops — the
  /// same lineariser the writes use, so walked and written keys agree by
  /// construction (pass a custom `_toRow` here iff the writes use it too).
  public func step<K, V>(
    m          : Indexed<K, V>,
    state      : State<K>,
    budgetRows : Nat,
    compare    : (implicit : (K, K) -> Order.Order),
    _toRow     : (implicit : V -> Row),
  ) : Bool {
    if (state.done) return true;
    let entries = switch (state.cursor) {
      case (?c)  { m.inner.entriesFrom(compare, c) };
      case null  { m.inner.entries() };
    };
    var left  = budgetRows;
    var first = true;
    for ((k, v) in entries) {
      // `entriesFrom` is INCLUSIVE and the cursor row is already indexed:
      // drop it, or a budget of 1 would re-index it forever and never
      // advance. (A cursor row deleted between steps just isn't there — the
      // seek lands on the next key, which never compares equal.)
      let isCursor = first and (switch (state.cursor) { case (?c) { compare(c, k) == #equal }; case null { false } });
      first := false;
      if (not isCursor) {
        if (left == 0) return false;   // budget spent, rows remain — resume here next call
        SecondaryIndex.indexOne<K>(m.ix, compare, k, _toRow(v), state.target);
        state.cursor := ?k;
        left -= 1;
      };
    };
    // The iterator ran out inside the budget: every pre-existing row is
    // indexed (live writes covered themselves via onChange) — flip ready.
    state.done := true;
    SecondaryIndex.markReady<K>(m.ix, state.target);
    true
  };

};
