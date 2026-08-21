// Small text / parsing helpers for the NEAR deposit detector.
// Named Hex.mo for parity with ethchain-deposit, but NEAR uses decimal amounts
// and case-insensitive account ids rather than hex, so the helpers here are
// lowercase-normalization and decimal string parsing.
//
// No canister state — every function is self-contained.

import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Char "mo:core/Char";

// Lowercase a NEAR account id. NEAR account ids are case-insensitive (top-level
// accounts and .near names are normalized to lowercase; implicit accounts are
// already lowercase hex), so lowercasing the watchedAddresses key (on
// register / unregister) AND the inbound event's owner (on match) gives an
// exact, case-insensitive comparison no matter the caller/RPC casing.
func lowerText(t : Text) : Text {
  var out = "";
  for (c in t.chars()) {
    let lc = switch (c) {
      case ('A') { 'a' }; case ('B') { 'b' }; case ('C') { 'c' }; case ('D') { 'd' };
      case ('E') { 'e' }; case ('F') { 'f' }; case ('G') { 'g' }; case ('H') { 'h' };
      case ('I') { 'i' }; case ('J') { 'j' }; case ('K') { 'k' }; case ('L') { 'l' };
      case ('M') { 'm' }; case ('N') { 'n' }; case ('O') { 'o' }; case ('P') { 'p' };
      case ('Q') { 'q' }; case ('R') { 'r' }; case ('S') { 's' }; case ('T') { 't' };
      case ('U') { 'u' }; case ('V') { 'v' }; case ('W') { 'w' }; case ('X') { 'x' };
      case ('Y') { 'y' }; case ('Z') { 'z' };
      case (_) { c };
    };
    out #= Char.toText(lc);
  };
  out;
};

// NEAR amounts are decimal strings (u128, e.g. yoctoNEAR). Motoko Nat is
// arbitrary-precision, so amounts up to ~3.4e38 fit. Non-digit chars are
// skipped (defensive against stray formatting), so a malformed amount parses
// to 0 and is dropped by the caller's amountRaw > 0 guard.
func decimalToNat(s : Text) : Nat {
  var acc : Nat = 0;
  for (c in s.chars()) {
    // sentinel 100 (not a valid digit) → skip this char
    let d : Nat = switch (c) {
      case ('0') { 0 }; case ('1') { 1 }; case ('2') { 2 }; case ('3') { 3 };
      case ('4') { 4 }; case ('5') { 5 }; case ('6') { 6 }; case ('7') { 7 };
      case ('8') { 8 }; case ('9') { 9 };
      case (_) { 100 };
    };
    if (d < 10) { acc := acc * 10 + d };
  };
  acc;
};

// Light sanity check for a NEAR account id: non-empty and no spaces. Full
// NEAR account-id validation (charset / length / top-level rules) is not
// enforced here — a malformed id simply never matches an on-chain event.
func isValidNearAccount(acc : Text) : Bool {
  if (acc.size() == 0) { return false };
  for (c in acc.chars()) {
    if (c == ' ' or c == '\n' or c == '\t') { return false };
  };
  true;
};

// Strip the "EVENT_JSON:" prefix from a NEAR event log line, returning the
// inner JSON object text. The prefix ends at the first ':'.
func eventJson(line : Text) : Text {
  let cs = Iter.toArray(line.chars());
  var i = 0;
  var found = false;
  while (i < cs.size()) {
    if (cs[i] == ':') { found := true; break };
    i += 1;
  };
  if (not found) { return "" };
  var out = "";
  var j = i + 1;
  while (j < cs.size()) { out #= Char.toText(cs[j]); j += 1 };
  out;
};
