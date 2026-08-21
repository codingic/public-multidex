// Base58 helpers for the Solana (SOL) deposit detector.
// Solana addresses are base58-encoded and case-sensitive, so there is NO
// case-normalization step. We provide a base58 <-> [Nat8] codec (used for ATA
// derivation in Ata.mo) and the strict 32-byte address validator.

import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

// Bitcoin-style base58 alphabet (used by Solana).
let ALPHABET : Text = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

func charValue(c : Char) : ?Nat {
  var i = 0;
  for (a in ALPHABET.chars()) {
    if (a == c) { return ?i };
    i += 1;
  };
  null;
};

func charAt(idx : Nat) : Char {
  var i = 0;
  for (a in ALPHABET.chars()) {
    if (i == idx) { return a };
    i += 1;
  };
  '1';
};

// Decode a base58 string to its byte array, or null if it contains characters
// outside the base58 alphabet.
func decodeBase58(s : Text) : ?[Nat8] {
  var leadingZeros = 0;
  var started = false;
  var num : Nat = 0;
  for (c in s.chars()) {
    if (not started and c == '1') { leadingZeros += 1; continue };
    started := true;
    switch (charValue(c)) {
      case (?v) { num := num * 58 + v };
      case null { return null };
    };
  };
  // big-endian byte representation of num
  var valueBytes : [Nat8] = [];
  if (num > 0) {
    var n = num;
    var rev : [Nat8] = [];
    while (n > 0) {
      rev := Array.concat<Nat8>([Nat8.fromNat(n % 256)], rev);
      n := n / 256;
    };
    valueBytes := rev;
  };
  // prepend the leading zero bytes
  var out : [Nat8] = [];
  var z = 0;
  while (z < leadingZeros) { out := Array.concat<Nat8>([Nat8.fromNat(0)], out); z += 1 };
  out := Array.concat(out, valueBytes);
  ?out;
};

// Encode a byte array as a base58 string.
func encodeBase58(bytes : [Nat8]) : Text {
  // count leading zero bytes
  var leadingZeros = 0;
  var i = 0;
  while (i < bytes.size() and bytes[i] == 0) { leadingZeros += 1; i += 1 };
  // little-endian big-integer value
  var num : Nat = 0;
  var j = i;
  while (j < bytes.size()) { num := num * 256 + Nat8.toNat(bytes[j]); j += 1 };
  // convert to base58 digits (big-endian), most significant first
  var digits : [Char] = [];
  if (num > 0) {
    var n = num;
    while (n > 0) {
      let r = n % 58;
      n := n / 58;
      digits := Array.concat<Char>([charAt(r)], digits);
    };
  };
  var s = "";
  var z = 0;
  while (z < leadingZeros) { s #= "1"; z += 1 };
  for (c in digits.vals()) { s #= Text.fromChar(c) };
  s;
};

// Strict Solana address check: valid base58 AND decodes to exactly 32 bytes
// (a genuine Ed25519 pubkey). Anything stored in `watchedAddresses` is a real
// address, so the exact-match lookup in the detector is meaningful.
func isValidSolanaAddress(s : Text) : Bool {
  switch (decodeBase58(s)) {
    case (?b) { b.size() == 32 };
    case null { false };
  };
};
