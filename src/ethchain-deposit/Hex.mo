// Pure hex / parsing helpers for the ETH deposit detector.
// No canister state — every function is self-contained.

import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Char "mo:core/Char";

// Lowercase the a-f hex digits (addresses/topics are matched case-insensitively).
func lowerHex(t : Text) : Text {
  var out = "";
  for (c in t.chars()) {
    let lc = switch (c) {
      case ('A') { 'a' }; case ('B') { 'b' }; case ('C') { 'c' }; case ('D') { 'd' };
      case ('E') { 'e' }; case ('F') { 'f' };
      case (_) { c };
    };
    out #= Char.toText(lc);
  };
  out;
};

// A 32-byte topic pads the 20-byte address with 24 zero hex chars. Take the
// last 40 hex chars and re-prefix with 0x to get a canonical address.
func topicToAddress(t : Text) : Text {
  let cs = Iter.toArray(t.chars());
  let len = cs.size();
  let start = if (len > 40) { len - 40 } else { 0 };
  var out = "0x";
  var i = start;
  while (i < len) { out #= Char.toText(cs[i]); i += 1 };
  out;
};

// Hex (0x-prefixed or bare) -> Nat.
func hexToNat(s : Text) : Nat {
  var acc : Nat = 0;
  var skipping : Nat = if (Text.startsWith(s, #text "0x")) { 2 } else { 0 };
  for (c in s.chars()) {
    if (skipping > 0) {
      skipping -= 1;
    } else {
      let d = switch (c) {
        case ('0') { 0 }; case ('1') { 1 }; case ('2') { 2 }; case ('3') { 3 };
        case ('4') { 4 }; case ('5') { 5 }; case ('6') { 6 }; case ('7') { 7 };
        case ('8') { 8 }; case ('9') { 9 }; case ('a') { 10 }; case ('b') { 11 };
        case ('c') { 12 }; case ('d') { 13 }; case ('e') { 14 }; case ('f') { 15 };
        case ('A') { 10 }; case ('B') { 11 }; case ('C') { 12 }; case ('D') { 13 };
        case ('E') { 14 }; case ('F') { 15 };
        case (_) { 0 }; // ignore stray chars
      };
      acc := acc * 16 + d;
    };
  };
  acc;
};

// Nat -> 0x-prefixed lowercase hex (used for trace_block's hex block height).
func natToHex(n : Nat) : Text {
  if (n == 0) { return "0x0" };
  var digits = "";
  var x = n;
  loop {
    let c = switch (x % 16) {
      case (0) { '0' }; case (1) { '1' }; case (2) { '2' }; case (3) { '3' };
      case (4) { '4' }; case (5) { '5' }; case (6) { '6' }; case (7) { '7' };
      case (8) { '8' }; case (9) { '9' }; case (10) { 'a' }; case (11) { 'b' };
      case (12) { 'c' }; case (13) { 'd' }; case (14) { 'e' }; case (15) { 'f' };
      case (_) { '0' };
    };
    digits := Char.toText(c) # digits;
    x := x / 16;
    if (x == 0) { break };
  };
  "0x" # digits;
};
