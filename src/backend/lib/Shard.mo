// Shard.mo — cursor-sharded walk over an ordered, Text-keyed Map.
//
// A periodic O(N) sweep of a large map inside one heartbeat message risks two
// things on a paid subnet: cost that grows with N, and — worse — a single
// oversized pass exceeding the message instruction limit, which TRAPS the whole
// heartbeat (stalling every maintenance job it drives). Sharding fixes both:
// process a bounded SLICE per tick, resuming from a cursor, so per-tick work is
// O(size) regardless of N. Over ceil(N/size) ticks ("an epoch") the whole map
// is covered exactly once; the caller then publishes and the cursor resets.
//
// This is the generic engine — the caller owns the cursor var, the per-key work
// (`visit`), and the publish-on-completion. mo:core Map.entriesFrom gives an
// O(log N) resume, so there is no wasted skip.

import Map "mo:core/Map";
import Text "mo:core/Text";

module {
  public type Step = {
    nextCursor : ?Text;   // store this; pass it back next tick
    completed  : Bool;    // true ⇒ the pass reached the end — publish + reset the cursor to null
  };

  // Visit up to `size` keys of `m`, starting AFTER `cursor` (null = from the
  // beginning of a fresh pass), calling `visit` on each in key order. `size`
  // must be ≥ 1. Adding keys < cursor mid-epoch defers them to the next pass;
  // keys ≥ cursor not yet reached are still included. A cursor key that was
  // removed since last tick is handled by entriesFrom resuming at the next key.
  public func step<V>(m : Map.Map<Text, V>, cursor : ?Text, size : Nat, visit : Text -> ()) : Step {
    // entriesFrom yields keys ≥ cursor (inclusive), so on resume it re-emits the
    // cursor key first — skip it (already done last tick).
    let iter = switch (cursor) {
      case (?c)  { Map.entriesFrom(m, Text.compare, c) };
      case null  { Map.entries(m) };
    };
    var processed = 0;
    var next = cursor;
    var completed = true;
    label scan for ((k, _) in iter) {
      if (cursor == ?k) { continue scan };
      visit(k);
      next := ?k;
      processed += 1;
      if (processed >= size) { completed := false; break scan };
    };
    { nextCursor = next; completed }
  };
}
