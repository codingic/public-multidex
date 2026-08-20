// Base58 helpers for the Solana (SOL) deposit detector.
// Solana addresses are base58-encoded and case-sensitive, so there is NO
// case-normalization step (unlike hex addresses). We only provide a base58 →
// Nat decoder for parsing token/lamport amounts embedded in jsonParsed results
// (jsonParsed returns amounts as base10 strings, but some base64 fields retain
// base58 — decoded here for completeness) and the alphabet check used to
// validate watched addresses.

import Text "mo:core/Text";
import Iter "mo:core/Iter";

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

// Decode a base58 string to a Nat. Used for the (rare) base58-encoded numeric
// fields; jsonParsed balances come back as base10 and are parsed separately.
func base58ToNat(s : Text) : Nat {
  var acc : Nat = 0;
  for (c in s.chars()) {
    switch (charValue(c)) {
      case (?v) { acc := acc * 58 + v };
      case null { return acc }; // ignore stray chars
    };
  };
  acc;
};

// Validate that a string is a well-formed base58 Solana address (no 0/O/I/l
// characters). Pure structural check — length is not enforced (variants exist).
func isValidBase58(s : Text) : Bool {
  for (c in s.chars()) {
    if (charValue(c) == null) { return false };
  };
  true;
};
