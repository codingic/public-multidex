// Unit tests for src/backend/lib/RateLimit.mo — the pure multi-window sliding
// limiter behind aiComplete. Times are in ns; helpers use seconds for brevity.

import RateLimit "../src/backend/lib/RateLimit";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

let S : Int = 1_000_000_000; // 1 second in ns
// The exact AI ladder from main.mo: 1/min, 20/h, 30/4h, 40/8h, 50/24h.
let LIMITS : [RateLimit.Window] = [
  (60 * S, 1, "minute"),
  (3_600 * S, 20, "hour"),
  (14_400 * S, 30, "4 hours"),
  (28_800 * S, 40, "8 hours"),
  (86_400 * S, 50, "24 hours"),
];
let WIDEST : Int = 86_400 * S;

func isOk(d : RateLimit.Decision) : Bool { switch (d) { case (#ok(_)) { true }; case _ { false } } };
func okLog(d : RateLimit.Decision) : [Int] { switch (d) { case (#ok(l)) { l }; case _ { Runtime.trap("expected #ok") } } };
func limLabel(d : RateLimit.Decision) : Text { switch (d) { case (#limited(l)) { l.windowLabel }; case _ { Runtime.trap("expected #limited") } } };
func limWait(d : RateLimit.Decision) : Int { switch (d) { case (#limited(l)) { l.waitNs }; case _ { Runtime.trap("expected #limited") } } };

Debug.print("── RateLimit.test ──");

// Empty history → allowed, and `now` is recorded.
let d0 = RateLimit.check([], 1_000 * S, LIMITS, WIDEST);
truth("empty history → ok", isOk(d0));
truth("ok records the call", okLog(d0) == [1_000 * S]);

// 1/minute: a second call 30s later is blocked by the minute window...
let afterOne = okLog(d0);
let d1 = RateLimit.check(afterOne, 1_030 * S, LIMITS, WIDEST);
truth("2nd call within 60s → limited", not isOk(d1));
truth("minute window is the one that trips", limLabel(d1) == "minute");
// ...and the wait is until the first call ages out: 1000 + 60 − 1030 = 30s.
truth("wait = 30s until the minute frees", limWait(d1) == 30 * S);

// At exactly 60s the first call has aged out (strict <), so it's allowed.
let d2 = RateLimit.check(afterOne, 1_060 * S, LIMITS, WIDEST);
truth("call at +60s → ok (strict window edge)", isOk(d2));

// Hourly cap: 20 calls one minute apart all pass the minute gate; the 21st
// trips the HOUR window, not the minute.
var log : [Int] = [];
var t : Int = 0;
var i = 0;
while (i < 20) {
  let d = RateLimit.check(log, t, LIMITS, WIDEST);
  truth("hourly fill call " # debug_show (i + 1) # " ok", isOk(d));
  log := okLog(d);
  t += 90 * S;   // 90s apart → never trips the 1/min gate, 20 land within the hour
  i += 1;
};
// 20 calls span 0..1710s (< 3600s), so all 20 are in the hour window. Next call
// (t=1800s, ≥90s after the last → minute ok) trips the hour cap of 20.
let dHour = RateLimit.check(log, t, LIMITS, WIDEST);
truth("21st within the hour → limited", not isOk(dHour));
truth("hour window trips (not minute)", limLabel(dHour) == "hour");
// Oldest in-window call was at t=0; it frees the hour slot at 0 + 3600. now=1800.
truth("hour wait = 1800s", limWait(dHour) == 1_800 * S);

// Pruning: a call far in the future (> widest) drops all stale history → ok,
// and the returned log holds only the new timestamp.
let dPrune = RateLimit.check(log, 200_000 * S, LIMITS, WIDEST);
truth("stale history pruned → ok", isOk(dPrune));
truth("pruned log keeps only the new call", okLog(dPrune) == [200_000 * S]);

// maxN == 0 window is treated as "no limit" (never traps on the index).
let dZero = RateLimit.check([5 * S, 6 * S], 7 * S, [(60 * S, 0, "off")], WIDEST);
truth("maxN=0 window → ok (no limit, no trap)", isOk(dZero));

Debug.print("── RateLimit.test PASSED ──");
