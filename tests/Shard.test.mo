// Unit tests for src/backend/lib/Shard.mo — the cursor-sharded map walk behind
// the heartbeat leaderboard recompute. Pins: full coverage exactly once per
// epoch, correct cursor advance, completion detection, and the edge cases
// (empty map, size ≥ N, size = 1, boundary tick).

import Shard "../src/backend/lib/Shard";
import Map "mo:core/Map";
import List "mo:core/List";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

func mk(keys : [Text]) : Map.Map<Text, Bool> {
  let m = Map.empty<Text, Bool>();
  for (k in keys.vals()) { Map.add(m, Text.compare, k, true) };
  m
};

// Drive full epochs to completion; return the flat sequence of visited keys and
// the number of ticks it took. Guards against a runaway loop.
func runEpoch(m : Map.Map<Text, Bool>, size : Nat) : { visited : [Text]; ticks : Nat } {
  let seen = List.empty<Text>();
  var cursor : ?Text = null;
  var ticks = 0;
  label loop_ loop {
    let r = Shard.step<Bool>(m, cursor, size, func(k) { List.add(seen, k) });
    cursor := r.nextCursor;
    ticks += 1;
    if (r.completed) { break loop_ };
    if (ticks > 1000) { Runtime.trap("runaway epoch") };
  };
  { visited = Iter.toArray(List.values(seen)); ticks }
};

Debug.print("── Shard.test ──");

// Empty map → one tick, completes immediately, visits nothing.
let e = runEpoch(mk([]), 2);
truth("empty map: 1 tick, 0 visited", e.ticks == 1 and e.visited.size() == 0);

// 5 keys, size 2. Keys are inserted out of order but visited in SORTED order
// (a,b,c,d,e), each exactly once, across a full epoch.
let m5 = mk(["d", "a", "e", "b", "c"]);
let r = runEpoch(m5, 2);
truth("5 keys size 2: all 5 visited once", r.visited.size() == 5);
truth("5 keys size 2: visited in sorted order", r.visited == ["a", "b", "c", "d", "e"]);
// ceil(5/2)=3 processing ticks; a boundary tick may add one → 3 or 4.
truth("5 keys size 2: bounded tick count", r.ticks >= 3 and r.ticks <= 4);

// size ≥ N → the whole map in a single completing tick.
let rBig = runEpoch(m5, 10);
truth("size ≥ N: one tick", rBig.ticks == 1);
truth("size ≥ N: all visited once, sorted", rBig.visited == ["a", "b", "c", "d", "e"]);

// size 1 → one key per tick, still full sorted coverage.
let r1 = runEpoch(m5, 1);
truth("size 1: all 5 visited once, sorted", r1.visited == ["a", "b", "c", "d", "e"]);

// A single step from a mid-epoch cursor skips the cursor key and advances.
let one = Shard.step<Bool>(m5, ?"b", 2, func(_) {});
truth("step from cursor 'b' skips b, next cursor advances past it", one.nextCursor == ?"d" and not one.completed);

// A second epoch (cursor reset to null) reproduces the same full coverage —
// i.e. completion truly resets and the walk is repeatable.
let r2 = runEpoch(m5, 2);
truth("second epoch: identical full coverage", r2.visited == ["a", "b", "c", "d", "e"]);

Debug.print("── Shard.test PASSED ──");
