// RateLimit.mo — pure, multi-window sliding rate limiter.
//
// A caller keeps an ascending list of call timestamps (ns). `check` prunes the
// list to the widest window, then tests every window: if any is already at its
// cap, the call is refused with the wait until a slot frees; otherwise `now` is
// appended and the new list returned. Pure (no state, no clock) so the caller
// owns storage and supplies `now` — which makes it unit-testable.

import Array "mo:core/Array";

module {
  // (durationNs, maxCalls, label) — refuse if `maxCalls` calls already fall
  // within the trailing `durationNs`.
  public type Window = (Int, Nat, Text);

  public type Decision = {
    // Allowed: store this list (it has `now` appended, stale entries pruned).
    #ok : [Int];
    // Refused: which window tripped, its cap, and ns until the oldest blocking
    // call ages out of that window. Storage is left unchanged (already bounded).
    // (`windowLabel`, not `label` — the latter is a Motoko reserved word.)
    #limited : { windowLabel : Text; maxN : Nat; waitNs : Int };
  };

  // `prior` MUST be ascending (oldest first) — the shape `check` itself returns.
  // `windows` may be in any order; every one is enforced. `widestNs` is the
  // prune horizon (use the largest window's duration).
  public func check(prior : [Int], now : Int, windows : [Window], widestNs : Int) : Decision {
    let kept = Array.filter<Int>(prior, func t = now - t < widestNs);
    for ((win, maxN, wlabel) in windows.vals()) {
      // maxN == 0 would refuse every call with no releasing slot; treat as "no
      // limit" instead of trapping on the index below.
      if (maxN > 0) {
        let inWin = Array.filter<Int>(kept, func t = now - t < win);
        if (inWin.size() >= maxN) {
          // Sorting is preserved by filter, so inWin is ascending. Dropping the
          // count below maxN needs the (size − maxN)-th oldest in-window call to
          // expire; it leaves the window at inWin[idx] + win. idx ≥ 0 by guard.
          let idx : Nat = inWin.size() - maxN;
          return #limited({ windowLabel = wlabel; maxN; waitNs = (inWin[idx] + win) - now });
        };
      };
    };
    // Append `now` (kept has no element for it yet).
    #ok(Array.tabulate<Int>(kept.size() + 1, func i = if (i < kept.size()) { kept[i] } else { now }))
  };
}
